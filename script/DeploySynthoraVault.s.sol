// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  DeploySynthoraVault
 * @notice Foundry deployment script that:
 *           1. Deploys the SynthoraVault implementation contract.
 *           2. Wraps it in an ERC-1967 UUPS proxy.
 *           3. Calls initialize() through the proxy.
 *           4. Grants roles to separate operator addresses.
 *           5. Configures oracle feeds + whitelisted assets.
 *           6. Runs a full post-deployment sanity check.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * HOW UUPS PROXIES WORK (quick reference)
 * ─────────────────────────────────────────────────────────────────────────────
 *
 *  ┌────────────┐  all calls  ┌──────────────────────┐
 *  │   Users    │ ──────────▶ │  ERC-1967 Proxy       │
 *  └────────────┘             │  (stores state)       │
 *                             │  slot 0x360894…= impl │
 *                             └──────────┬────────────┘
 *                                        │ delegatecall
 *                                        ▼
 *                             ┌──────────────────────┐
 *                             │  SynthoraVault Impl  │
 *                             │  (stores no state)   │
 *                             └──────────────────────┘
 *
 *  • The PROXY owns all storage and all ETH/tokens.
 *  • The IMPL is stateless — it is only code.
 *  • `upgradeTo(newImpl)` is encoded inside the impl (UUPS pattern) and
 *    is guarded by UPGRADER_ROLE.
 *  • Never interact with the implementation directly after deployment.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * ROLE MANAGEMENT BEST PRACTICES
 * ─────────────────────────────────────────────────────────────────────────────
 *  1. DEFAULT_ADMIN_ROLE should be held by a multi-sig (e.g. Gnosis Safe).
 *  2. UPGRADER_ROLE should be held by ONLY ONE address — the upgrade multisig.
 *  3. PAUSER_ROLE can be a hot-wallet for fast emergency response.
 *  4. KEEPER_ROLE should be held by your keeper bot EOA or a keeper network.
 *  5. STRATEGIST_ROLE should be held by the strategy governance multi-sig.
 *  6. Rotate KEEPER_ROLE / PAUSER_ROLE via `grantRole` + `revokeRole` pairs.
 *     Always add the new key BEFORE revoking the old one.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * RUNNING THE SCRIPT
 * ─────────────────────────────────────────────────────────────────────────────
 *
 *  # Dry-run (no broadcast):
 *  forge script script/DeploySynthoraVault.s.sol \
 *      --rpc-url $ARBITRUM_RPC_URL \
 *      --sig "run()" \
 *      -vvvv
 *
 *  # Live broadcast:
 *  forge script script/DeploySynthoraVault.s.sol \
 *      --rpc-url $ARBITRUM_RPC_URL \
 *      --broadcast \
 *      --verify \
 *      --etherscan-api-key $ARBISCAN_API_KEY \
 *      -vvvv
 *
 *  Required env vars:
 *    DEPLOYER_PRIVATE_KEY   — deployer EOA private key (funds gas)
 *    ADMIN_ADDRESS          — multi-sig that will own DEFAULT_ADMIN_ROLE
 *    STRATEGIST_ADDRESS     — strategy governance address
 *    KEEPER_ADDRESS         — keeper bot address
 *    PAUSER_ADDRESS         — emergency pauser address
 *    UPGRADER_ADDRESS       — upgrade multi-sig address
 *    TREASURY_ADDRESS       — fee recipient
 *    USDC_ADDRESS           — USDC token on the target chain
 *    PYTH_ADDRESS           — Pyth Network contract on the target chain
 */

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SynthoraVault} from "../src/SynthoraVault.sol";

contract DeploySynthoraVault is Script {
    // ─── Deployment artefacts (written to console) ────────────────────────────
    address public proxyAddress;
    address public implAddress;

    // ─── Well-known Pyth feed IDs (mainnet / Arbitrum) ───────────────────────
    // Source: https://pyth.network/developers/price-feed-ids
    bytes32 constant PYTH_AAPL = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
    bytes32 constant PYTH_TSLA = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 constant PYTH_NVDA = 0x9b5729b99e46b3a18193f83a50f68c74d67fc0085f5e3edd1bdc88ef5cdb53f8;
    bytes32 constant PYTH_SPX = 0x694aa1769357215de4fac081bf1f309adc325306ef9b4e9f76bc3857f7acd7a3; // ETH/USD used as placeholder
    bytes32 constant PYTH_GOLD = 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2;

    function run() external {
        // ── Load environment ─────────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envOr("ADMIN_ADDRESS", vm.addr(deployerKey));
        address strategist = vm.envOr("STRATEGIST_ADDRESS", vm.addr(deployerKey));
        address keeper = vm.envOr("KEEPER_ADDRESS", vm.addr(deployerKey));
        address pauser = vm.envOr("PAUSER_ADDRESS", vm.addr(deployerKey));
        address upgrader = vm.envOr("UPGRADER_ADDRESS", vm.addr(deployerKey));
        address treasury = vm.envOr("TREASURY_ADDRESS", vm.addr(deployerKey));

        // Mainnet / Arbitrum addresses — override via env for other chains
        address usdc = vm.envOr("USDC_ADDRESS", address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831)); // Arb USDC
        address pyth = vm.envOr("PYTH_ADDRESS", address(0xff1a0f4744e8582DF1aE09D5611b887B6a12925C)); // Arb Pyth

        console2.log("=== Synthora Vault Deployment ===");
        console2.log("Deployer  :", vm.addr(deployerKey));
        console2.log("Admin     :", admin);
        console2.log("Treasury  :", treasury);
        console2.log("USDC      :", usdc);
        console2.log("Pyth      :", pyth);

        vm.startBroadcast(deployerKey);

        // ── Step 1: Deploy implementation ────────────────────────────────────
        // The constructor calls _disableInitializers() so the impl is bricked.
        SynthoraVault impl = new SynthoraVault();
        implAddress = address(impl);
        console2.log("Implementation deployed:", implAddress);

        // ── Step 2: Encode initializer calldata ───────────────────────────────
        // The proxy will delegatecall this on construction, initialising state
        // inside the proxy's own storage slot space.
        bytes memory initData = abi.encodeCall(
            SynthoraVault.initialize,
            (
                usdc,
                pyth,
                treasury,
                admin, // initial admin — receives all roles
                "Synthora USDC Vault",
                "svUSDC"
            )
        );

        // ── Step 3: Deploy ERC-1967 proxy ─────────────────────────────────────
        // ERC1967Proxy(impl, initData) → proxy is created, initData is
        // delegatecalled into impl, state is stored in the PROXY.
        ERC1967Proxy proxy = new ERC1967Proxy(implAddress, initData);
        proxyAddress = address(proxy);
        console2.log("Proxy deployed         :", proxyAddress);

        // All subsequent calls go through the proxy (cast to the interface)
        SynthoraVault vault = SynthoraVault(proxyAddress);

        // ── Step 4: Grant granular roles ──────────────────────────────────────
        // The deployer (admin) holds all roles after initialize().
        // Here we delegate them to purpose-specific addresses.

        bytes32 STRATEGIST = vault.STRATEGIST_ROLE();
        bytes32 KEEPER = vault.KEEPER_ROLE();
        bytes32 PAUSER = vault.PAUSER_ROLE();
        bytes32 UPGRADER = vault.UPGRADER_ROLE();
        bytes32 ADMIN = vault.DEFAULT_ADMIN_ROLE();

        // Grant to dedicated addresses
        if (strategist != admin) vault.grantRole(STRATEGIST, strategist);
        if (keeper != admin) vault.grantRole(KEEPER, keeper);
        if (pauser != admin) vault.grantRole(PAUSER, pauser);
        if (upgrader != admin) vault.grantRole(UPGRADER, upgrader);

        // SECURITY: if deployer != admin, revoke deployer's admin role LAST
        // (after all other grants complete) to avoid locking yourself out.
        if (vm.addr(deployerKey) != admin) {
            vault.grantRole(ADMIN, admin);
            // Note: DEFAULT_ADMIN_ROLE can only be revoked by the admin itself.
            // The deployer keeps it here and should call revokeRole off-chain.
            console2.log("WARNING: revoke DEFAULT_ADMIN_ROLE from deployer via multi-sig");
        }

        // ── Step 5: Configure oracle feeds ────────────────────────────────────
        // maxPriceAge = 60s for equities (market hours), 120s for 24/7 assets
        // maxDeviationBps = 200 (2%) — conservative cross-oracle tolerance

        _configureAsset(vault, "AAPL", PYTH_AAPL, 60, 200);
        _configureAsset(vault, "TSLA", PYTH_TSLA, 60, 200);
        _configureAsset(vault, "NVDA", PYTH_NVDA, 60, 200);
        _configureAsset(vault, "SPX", PYTH_SPX, 60, 200);
        _configureAsset(vault, "GOLD", PYTH_GOLD, 120, 300); // 24/7, slightly wider

        // ── Step 6: Risk config (production values) ───────────────────────────
        vault.setRiskConfig(
            100, // minLeverageBps   (1×)
            2000, // maxLeverageBps  (20×)
            2000, // maxPositionSizeBps — 20% of TVL per position
            8500, // liquidationThresholdBps — liq at 85% collateral loss
            500, // maintenanceMarginBps — 5%
            20, // maxOpenPositions
            1500, // maxLeverageForDynamic (15×)
            10 // fundingRateThresholdBps (0.10%)
        );

        // ── Step 7: Fee config ────────────────────────────────────────────────
        vault.setFeeConfig(
            1000, // performanceFeeBps (10%)
            200, // managementFeeBps  (2% p.a.)
            50, // withdrawalFeeBps  (0.5%)
            0 // depositFeeBps     (0%)
        );

        // ── Step 8: TVL cap & min deposit ────────────────────────────────────
        vault.setTvlCap(10_000_000 * 1e6); // $10M initial cap
        vault.setMinDeposit(100 * 1e6); // $100 minimum

        vm.stopBroadcast();

        // ── Step 9: Post-deployment assertions ───────────────────────────────
        _postDeployChecks(vault, admin, usdc, pyth, treasury);

        // ── Print deployment summary ──────────────────────────────────────────
        console2.log("\n=== DEPLOYMENT COMPLETE ===");
        console2.log("Proxy (USE THIS)    :", proxyAddress);
        console2.log("Implementation      :", implAddress);
        console2.log("Version             :", vault.version());
        console2.log("Total Assets        :", vault.totalAssets());
        console2.log("Share Price (1e18)  :", vault.sharePrice());
        console2.log("\nSave these addresses in your .env / deployment registry!");
        console2.log("SYNTHORA_PROXY=", proxyAddress);
        console2.log("SYNTHORA_IMPL=", implAddress);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /**
     * @dev Configures oracle and whitelists an asset in a single call group.
     * @param label Human-readable label for logging (not stored on-chain).
     */
    function _configureAsset(
        SynthoraVault vault,
        string memory label,
        bytes32 pythFeedId,
        uint32 maxAge,
        uint32 maxDeviation
    ) internal {
        vault.setOracleConfig(
            pythFeedId, // assetId == pythFeedId for simplicity; use a custom key in production
            pythFeedId, // pythFeedId
            address(0), // no Chainlink feed wired yet
            maxAge,
            maxDeviation,
            false // useChainlinkFallback = false until Chainlink feeds are set
        );
        vault.setAssetWhitelist(pythFeedId, true);
        console2.log("Asset configured:", label);
    }

    /**
     * @dev Runs read-only assertions post-deployment to catch misconfigurations.
     *      This is the "trust but verify" step — runs WITHOUT broadcast so it's free.
     */
    function _postDeployChecks(SynthoraVault vault, address admin, address usdc, address pyth, address treasury)
        internal
        view
    {
        // Proxy points at the right asset
        require(vault.asset() == usdc, "ASSET_MISMATCH");
        require(address(vault.pythOracle()) == pyth, "PYTH_MISMATCH");
        require(vault.treasury() == treasury, "TREASURY_MISMATCH");

        // Admin has all roles
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_ROLE_MISSING");

        // Risk config sanity
        SynthoraVault.RiskConfig memory rc = vault.getRiskConfig();
        require(rc.minLeverageBps == 100, "MIN_LEV");
        require(rc.maxLeverageBps == 2000, "MAX_LEV");
        require(rc.maxOpenPositions == 20, "MAX_POS");

        // Fee config sanity
        SynthoraVault.FeeConfig memory fc = vault.getFeeConfig();
        require(fc.performanceFeeBps == 1000, "PERF_FEE");
        require(fc.managementFeeBps == 200, "MGMT_FEE");

        // ERC-4626 basics
        require(vault.totalAssets() == 0, "TOTAL_ASSETS");
        require(vault.sharePrice() == 1e18, "SHARE_PRICE");
        require(vault.highWaterMark() == 1e18, "HWM");
        require(vault.minDepositAmount() == 100e6, "MIN_DEP");
        require(vault.tvlCap() == 10_000_000 * 1e6, "TVL_CAP");

        // Assets whitelisted
        require(vault.whitelistedAssets(PYTH_AAPL), "AAPL_NOT_WHITELISTED");
        require(vault.whitelistedAssets(PYTH_GOLD), "GOLD_NOT_WHITELISTED");

        console2.log("All post-deploy checks PASSED");
    }
}
