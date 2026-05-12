// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SynthoraVault} from "../src/SynthoraVault.sol";
// Import the new version when it exists:
// import {SynthoraVaultV2} from "../src/SynthoraVaultV2.sol";

contract UpgradeSynthoraVault is Script {
    // ─── New implementation placeholder ──────────────────────────────────────
    // Replace with the actual V2 contract when the upgrade is ready.
    // For now this script re-deploys V1 (no-op upgrade) as a demonstration.
    // type NewImpl = SynthoraVaultV2;

    function run() external {
        // ── Load environment ─────────────────────────────────────────────────
        uint256 upgraderKey = vm.envUint("UPGRADER_PRIVATE_KEY");
        address upgraderAddr = vm.addr(upgraderKey);
        address proxyAddr = vm.envAddress("SYNTHORA_PROXY");
        uint256 expectedOldVer = vm.envOr("EXPECTED_OLD_VERSION", uint256(1));

        // console2.log("=== Synthora Vault Upgrade ===");
        console2.log("Upgrader     :", upgraderAddr);
        console2.log("Proxy        :", proxyAddr);

        // Cast the proxy address to the vault interface for pre-upgrade checks
        SynthoraVault proxy = SynthoraVault(proxyAddr);

        // ── Pre-upgrade checks (read-only, no broadcast) ──────────────────────
        _preUpgradeChecks(proxy, upgraderAddr, expectedOldVer);

        vm.startBroadcast(upgraderKey);

        // ── Step 1: Deploy new implementation ────────────────────────────────
        // IMPORTANT: The new impl's constructor MUST call _disableInitializers().
        // Replace `SynthoraVault` with `SynthoraVaultV2` for a real upgrade.
        SynthoraVault newImpl = new SynthoraVault();
        address newImplAddr = address(newImpl);
        console2.log("New implementation     :", newImplAddr);

        // ── Step 2: Verify new impl version is higher ─────────────────────────
        // This guard prevents accidentally downgrading or re-deploying the same version.
        // (In a real upgrade, SynthoraVaultV2.VERSION would be 2.)
        uint256 newVersion = newImpl.version();
        // For a real upgrade: require(newVersion > expectedOldVer, "VERSION_NOT_HIGHER");
        console2.log("New impl version       :", newVersion);

        // ── Step 3: Call upgradeToAndCall on the proxy ───────────────────────
        // `upgradeToAndCall(addr, "")` with empty calldata does a pure upgrade
        // with no re-initialisation — correct for most upgrades.
        //
        // If V2 adds a new `initializeV2(...)` function that sets NEW state
        // variables introduced in V2, pass its encoded calldata here:
        //   bytes memory v2Init = abi.encodeCall(SynthoraVaultV2.initializeV2, (newParam));
        //   proxy.upgradeToAndCall(newImplAddr, v2Init);
        //
        // WARNING: Never pass calldata that calls __ERC20_init or any other
        // base initialiser — they would reset already-set state.

        proxy.upgradeToAndCall(newImplAddr, "");
        console2.log("Upgrade transaction submitted");

        vm.stopBroadcast();

        // ── Post-upgrade checks (read-only) ───────────────────────────────────
        _postUpgradeChecks(proxy, newImplAddr, expectedOldVer);

        console2.log("\n UPGRADE COMPLETE ");
        console2.log("Old impl (keep for rollback)  save this address!");
        console2.log("New impl :", newImplAddr);
        console2.log("Proxy    :", proxyAddr);
    }

    // ─── Pre-upgrade validation ───────────────────────────────────────────────

    /**
     * @dev Assertions that must pass BEFORE broadcasting the upgrade tx.
     *      Run these against a mainnet fork first:
     *        forge script ... --fork-url $ARBITRUM_RPC_URL
     */
    function _preUpgradeChecks(SynthoraVault proxy, address upgrader, uint256 expectedVersion) internal view {
        // 1. Caller holds UPGRADER_ROLE
        require(proxy.hasRole(proxy.UPGRADER_ROLE(), upgrader), "PRE: upgrader lacks UPGRADER_ROLE");

        // 2. Proxy is not paused (upgrade during a pause is risky — users can't exit)
        //    Relax this check only if the upgrade IS the emergency fix.
        //    require(!proxy.paused(), "PRE: vault is paused — unpause before upgrading");

        // 3. Current version matches expectation (prevents double-upgrade)
        require(proxy.version() == expectedVersion, "PRE: version mismatch : already upgraded or wrong proxy?");

        // 4. No emergency mode
        require(!proxy.emergencyMode(), "PRE: emergency mode active  resolve before upgrading");

        // 5. Basic invariant: totalAssets >= totalCollateralLocked
        require(
            proxy.totalAssets() >= proxy.totalCollateralLocked(),
            "PRE: totalAssets < collateralLocked : vault is insolvent!"
        );

        console2.log("Pre-upgrade checks PASSED");
    }

    /**
     * @dev Assertions that must pass AFTER the upgrade tx is mined.
     *      Critical state must be identical to pre-upgrade.
     */
    function _postUpgradeChecks(SynthoraVault proxy, address newImplAddr, uint256 oldVersion) internal view {
        // 1. ERC-1967 implementation slot points to the new impl
        //    (OpenZeppelin's ERC1967Utils.getImplementation reads slot directly)
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address storedImpl;
        assembly { storedImpl := sload(implSlot) }
        require(storedImpl == newImplAddr, "POST: impl slot mismatch");

        // 2. Version bumped (for a real V2 upgrade this would be > oldVersion)
        uint256 newVer = proxy.version();
        console2.log("Post-upgrade version :", newVer);
        // require(newVer > oldVersion, "POST: version not bumped");
        oldVersion; // suppress unused warning for this demo

        // 3. All roles are still intact
        require(proxy.hasRole(proxy.DEFAULT_ADMIN_ROLE(), proxy.owner()), "POST: admin role lost");

        // 4. State variables still readable (storage layout intact)
        proxy.totalAssets();
        proxy.activePositionCount();
        proxy.highWaterMark();
        proxy.getFeeConfig();
        proxy.getRiskConfig();

        console2.log("Post-upgrade checks PASSED");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EXAMPLE: What SynthoraVaultV2.sol would look like
// (Do NOT deploy this — it is here as a reference template only)
// ─────────────────────────────────────────────────────────────────────────────
//
// contract SynthoraVaultV2 is SynthoraVault {
//
//     /// @dev New state variable added in V2.
//     ///      Appended AFTER all V1 variables and BEFORE __gap.
//     ///      __gap must be reduced from 50 to 49.
//     uint256 public newFeatureParam;
//
//     /// @dev Version constant bumped to 2.
//     uint256 public constant VERSION = 2; // shadows V1 constant
//
//     /// @notice V2 initializer — called ONLY ONCE via upgradeToAndCall.
//     ///         Must NOT call any __*_init() functions (they re-initialise base state).
//     function initializeV2(uint256 _newFeatureParam) external reinitializer(2) {
//         newFeatureParam = _newFeatureParam;
//     }
//
//     /// ... new functions, bug fixes, etc. ...
//
//     /// @dev Reduced from 50 to 49 (one new slot consumed).
//     uint256[49] private __gap;
// }
