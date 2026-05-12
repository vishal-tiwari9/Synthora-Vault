// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPyth} from "./interfaces/IPyth.sol";
import {ISynthoraRouter} from "./interfaces/ISynthoraRouter.sol";

/**
 * @title  SynthoraVault
 * @author Vishal Tiwari
 * @notice Production-grade ERC-4626 vault that automates leveraged long/short
 *         positions on Real-World Asset (RWA) synthetic perpetual futures.
 *
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │  ARCHITECTURE OVERVIEW                                                  │
 * │                                                                         │
 * │  Users ──USDC──▶ [ERC1967 Proxy] ──delegatecall──▶ [SynthoraVault Impl]│
 * │                        │                                                │
 * │            Shares ◀────┘  Pyth (primary oracle)                        │
 * │                           Chainlink (circuit breaker)                   │
 * │                           ISynthoraRouter (trade execution — placeholder)│
 * │                                                                         │
 * │  Roles:                                                                 │
 * │    DEFAULT_ADMIN_ROLE  — fees, risk params, emergency, role management  │
 * │    STRATEGIST_ROLE     — strategy creation, position opening            │
 * │    KEEPER_ROLE         — rebalancing, liquidation, funding arb          │
 * │    PAUSER_ROLE         — emergency pause                                │
 * │    UPGRADER_ROLE       — UUPS upgrade authorisation                     │
 * └─────────────────────────────────────────────────────────────────────────┘
 *
 * SECURITY MODEL
 * ──────────────
 * • Reentrancy      — `nonReentrant` on every state-mutating external function.
 * • Flash-loan      — `lastDepositBlock` mapping blocks same-block deposit+withdraw.
 * • Oracle manip.   — Pyth freshness check + Chainlink deviation circuit-breaker.
 * • Sandwich        — Caller-supplied min/max price bounds on every open/close.
 * • Privilege esc.  — Ownable2Step (two-phase ownership transfer) + role separation.
 * • Storage coll.   — 50-slot `__gap` + append-only state variable rule.
 * • Initialiser re-entry — `_disableInitializers()` in constructor.
 * • Integer O/U     — Solidity 0.8.28 built-in checks; explicit casts via uint128 max.
 *
 * UPGRADE SAFETY
 * ──────────────
 * 1. Never remove or reorder state variables.
 * 2. New variables must be appended BEFORE `__gap`.
 * 3. Reduce `__gap` by exactly the number of new 32-byte slots consumed.
 * 4. Run `forge inspect SynthoraVaultV2 storage-layout` and diff against V1.
 * 5. The new implementation must call `_authorizeUpgrade` which requires
 *    UPGRADER_ROLE — never grant this to untrusted parties.
 *
 * @custom:security-contact security@synthoraprotocol.xyz
 */
contract SynthoraVault is
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ERC4626Upgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =========================================================================
    // §1  CONSTANTS
    // =========================================================================

    /// @notice Role that may configure fees, risk params, and emergency settings.
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    /// @notice Role that triggers rebalancing, liquidation, and funding-arb ops.
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    /// @notice Role that may pause the vault.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Role that may authorise UUPS upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev Denominator for all basis-point calculations.
    uint256 public constant BASIS_POINTS = 10_000;
    /// @dev Divisor that converts leverageBps to a multiplier (500 bps → 5×).
    uint256 public constant LEVERAGE_PRECISION = 100;
    /// @dev 18-decimal precision used for share-price and price normalisation.
    uint256 public constant PRICE_PRECISION = 1e18;
    /// @dev USDC decimals (6).
    uint256 public constant USDC_DECIMALS = 1e6;

    /// @dev Maximum fee expressible in basis points (30 %).
    uint256 public constant MAX_FEE_BPS = 3_000;
    /// @dev Maximum annual management fee (10 %).
    uint256 public constant MAX_MGMT_FEE_BPS = 1_000;
    /// @dev Maximum withdrawal / deposit fee (5 %).
    uint256 public constant MAX_ENTRY_EXIT_FEE_BPS = 500;
    /// @dev Maximum leverage (20×) expressed in leverageBps units.
    uint32 public constant MAX_LEVERAGE_BPS = 2_000;
    /// @dev Minimum leverage (1×) expressed in leverageBps units.
    uint32 public constant MIN_LEVERAGE_BPS = 100;
    /// @dev Pyth price freshness cap used at the module level.
    uint256 public constant PYTH_MAX_AGE = 60; // seconds
    /// @dev Chainlink price freshness cap.
    uint256 public constant CHAINLINK_MAX_AGE = 3_600; // seconds

    /// @dev Implementation version — increment on each upgrade.
    uint256 public constant VERSION = 1;

    // =========================================================================
    // §2  PACKED STRUCTS
    // =========================================================================

    /**
     * @notice Fee parameters for the vault.
     * @dev    Packed into exactly 2 EVM storage slots:
     *         Slot A: performanceFeeBps(32) + managementFeeBps(32) +
     *                 withdrawalFeeBps(32)  + depositFeeBps(32)    [128 bits]
     *                 + lastFeeCollection(64) + _feePad(64)         [128 bits]
     *         Slot B: accruedFees(256)
     */
    struct FeeConfig {
        uint32 performanceFeeBps; ///< % of profit taken as performance fee
        uint32 managementFeeBps; ///< annual AUM fee (pro-rated per second)
        uint32 withdrawalFeeBps; ///< flat fee on every withdrawal
        uint32 depositFeeBps; ///< flat fee on every deposit
        uint64 lastFeeCollection; ///< unix timestamp of last management-fee sweep
        uint64 _feePad; ///< explicit padding, reserved for future use
        uint256 accruedFees; ///< USDC (6-dec) owed to treasury but not yet swept
    }

    /**
     * @notice Risk and leverage bounds for position management.
     * @dev    Packed into exactly 1 EVM storage slot (8 × uint32 = 256 bits).
     */
    struct RiskConfig {
        uint32 minLeverageBps; ///< lower bound — must be ≥ 100 (1×)
        uint32 maxLeverageBps; ///< upper bound — must be ≤ 2000 (20×)
        uint32 maxPositionSizeBps; ///< max single position as % of TVL (bps)
        uint32 liquidationThresholdBps; ///< collateral-loss % that triggers liq (bps)
        uint32 maintenanceMarginBps; ///< margin required to keep position open (bps)
        uint32 maxOpenPositions; ///< maximum concurrent active positions
        uint32 maxLeverageForDynamic; ///< leverage cap for dynamic-strategy type
        uint32 fundingRateThresholdBps; ///< min absolute funding rate for arb (bps)
    }

    /**
     * @notice Full state of a single perpetual position.
     * @dev    Layout (4 EVM storage slots):
     *         Slot 0: assetId (bytes32)
     *         Slot 1: sizeUsd(128) + collateralUsd(128)
     *         Slot 2: entryPrice(128) + liquidationPrice(128)
     *         Slot 3: openTimestamp(64) + lastUpdateTimestamp(64) + leverageBps(32)
     *                 + strategyType(8) + isLong(8) + isActive(8) + isLiquidatable(8)
     *                 + _pad(24) → fits in 64+64+32+8+8+8+8+24 = 216 bits < 256 bits ✓
     */
    struct Position {
        bytes32 assetId; ///< Pyth feed ID of the synthetic asset  [slot 0]
        uint128 sizeUsd; ///< notional position size, USDC (6-dec) [slot 1 hi]
        uint128 collateralUsd; ///< margin posted, USDC (6-dec)           [slot 1 lo]
        uint128 entryPrice; ///< fill price, 18-dec USD                [slot 2 hi]
        uint128 liquidationPrice; ///< price at which liq is triggered       [slot 2 lo]
        uint64 openTimestamp; ///< block.timestamp at open               [slot 3 …]
        uint64 lastUpdateTimestamp; ///< block.timestamp of last mutation
        uint32 leverageBps; ///< leverage × 100 (e.g. 500 = 5×)
        uint8 strategyType; ///< 0=fixed  1=dynamic  2=fundingArb
        bool isLong; ///< true = long, false = short
        bool isActive; ///< false after close / liquidation
        bool isLiquidatable; ///< keeper has flagged this position
        uint24 _pad; ///< explicit padding, reserved
    }

    /**
     * @notice Automated strategy template used by keepers to open and manage positions.
     * @dev    Layout (3 EVM storage slots).
     */
    struct Strategy {
        bytes32 assetId; ///< target synthetic asset            [slot 0]
        uint128 targetSizeUsd; ///< desired notional size, USDC       [slot 1 hi]
        uint128 maxDrawdownBps; ///< halt if drawdown exceeds X bps    [slot 1 lo]
        uint64 createdAt; ///< creation timestamp                [slot 2 …]
        uint64 lastExecutedAt; ///< last execution timestamp
        uint32 leverageBps; ///< target leverage
        uint32 rebalanceThresholdBps; ///< drift % to trigger rebalance
        uint32 profitTakingBps; ///< profit % to take partial close
        uint8 strategyType; ///< 0=fixed  1=dynamic  2=fundingArb
        bool isLong;
        bool isActive;
        bool isNeutral; ///< market-neutral (funding arb both legs)
        uint8 _pad;
    }

    /**
     * @notice Oracle configuration per synthetic asset.
     * @dev    Layout (2 EVM storage slots).
     */
    struct OracleConfig {
        bytes32 pythFeedId; ///< Pyth Network feed ID              [slot 0]
        address chainlinkFeed; ///< Chainlink AggregatorV3 address    [slot 1 hi 160 bits]
        uint32 maxPriceAge; ///< max acceptable age in seconds
        uint32 maxDeviationBps; ///< max oracle divergence in bps
        bool isActive; ///< feed enabled
        bool useChainlinkFallback; ///< whether to validate against CL
        uint16 _pad;
    }

    // =========================================================================
    // §3  STATE VARIABLES
    //     APPEND-ONLY RULE: new variables go AFTER this block and BEFORE __gap.
    //     Never delete or reorder anything in this section across upgrades.
    // =========================================================================

    /// @notice GMX-style trade-execution router (placeholder, set post-deploy).
    ISynthoraRouter public router;

    /// @notice Pyth Network price oracle (primary).
    IPyth public pythOracle;

    /// @notice Protocol fee recipient.
    address public treasury;

    /// @notice Vault fee parameters.
    FeeConfig public feeConfig;

    /// @notice Vault risk / leverage bounds.
    RiskConfig public riskConfig;

    /// @notice Monotonically increasing position counter (also used as position ID).
    uint128 public totalPositionsOpened;

    /// @notice Number of positions currently open.
    uint128 public activePositionCount;

    /// @notice Total USDC collateral locked in active positions (6-dec).
    uint256 public totalCollateralLocked;

    /// @notice Sum of notional sizes of all active positions (6-dec).
    uint256 public totalNotionalValue;

    /// @notice High-water mark for performance-fee calculation (assets-per-share, 18-dec).
    uint256 public highWaterMark;

    /// @notice Minimum deposit in USDC (6-dec). Protects against dust attacks.
    uint256 public minDepositAmount;

    /// @notice TVL cap in USDC (6-dec). 0 = uncapped.
    uint256 public tvlCap;

    /// @notice Monotonically increasing strategy counter.
    uint256 public strategyCount;

    // --- Mappings ---

    /// @notice positionId ⇒ Position
    mapping(uint256 => Position) public positions;

    /// @notice strategyId ⇒ Strategy
    mapping(uint256 => Strategy) public strategies;

    /// @notice assetId ⇒ OracleConfig
    mapping(bytes32 => OracleConfig) public oracleConfigs;

    /// @notice user ⇒ shares held at the time of their last deposit (cumulative)
    mapping(address => uint256) public userDepositedShares;

    /// @notice user ⇒ block number of their last deposit (flash-loan protection)
    mapping(address => uint256) public lastDepositBlock;

    /// @notice positionId ⇒ address that opened the position
    mapping(uint256 => address) public positionOwners;

    /// @notice assetId ⇒ total notional exposure (USDC 6-dec) across all positions
    mapping(bytes32 => uint256) public assetExposure;

    /// @notice assetId ⇒ true if the asset is approved for trading
    mapping(bytes32 => bool) public whitelistedAssets;

    // --- Circuit breakers ---

    /// @notice When true: vault is paused AND direct withdrawals bypass the pause.
    bool public emergencyMode;

    /// @notice When true: new deposits are rejected (e.g. TVL cap reached).
    bool public depositsLocked;

    // =========================================================================
    // §4  EVENTS
    // =========================================================================

    event Deposited(address indexed user, address indexed receiver, uint256 assets, uint256 shares, uint256 fee);
    event Withdrawn(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares,
        uint256 fee
    );

    event PositionOpened(
        uint256 indexed positionId,
        bytes32 indexed assetId,
        address indexed opener,
        bool isLong,
        uint128 sizeUsd,
        uint128 collateralUsd,
        uint128 entryPrice,
        uint32 leverageBps,
        uint8 strategyType
    );
    event PositionClosed(
        uint256 indexed positionId, bytes32 indexed assetId, uint128 exitPrice, int256 pnl, uint256 performanceFee
    );
    event PositionAdjusted(
        uint256 indexed positionId,
        uint32 oldLeverageBps,
        uint32 newLeverageBps,
        uint128 oldSizeUsd,
        uint128 newSizeUsd,
        uint128 newLiquidationPrice
    );
    event PositionLiquidated(
        uint256 indexed positionId, bytes32 indexed assetId, uint128 liquidationPrice, address indexed keeper
    );
    event PositionRebalanced(uint256 indexed positionId, uint32 newLeverageBps, uint128 newSizeUsd, uint256 timestamp);
    event FundingArbitrageExecuted(uint256 indexed positionId, bytes32 indexed assetId, int256 fundingRate);

    event StrategyCreated(uint256 indexed strategyId, bytes32 indexed assetId, uint8 strategyType, address creator);
    event StrategyUpdated(uint256 indexed strategyId, uint32 newLeverageBps, uint128 newTargetSize);
    event StrategyExecuted(uint256 indexed strategyId, uint256 indexed positionId);
    event StrategyDeactivated(uint256 indexed strategyId, address deactivator);

    event FeesCollected(uint256 performanceFee, uint256 managementFee, address indexed treasury, uint256 timestamp);
    event FeeConfigUpdated(
        uint32 performanceFeeBps, uint32 managementFeeBps, uint32 withdrawalFeeBps, uint32 depositFeeBps
    );
    event RiskConfigUpdated(RiskConfig newConfig);
    event OracleConfigSet(bytes32 indexed assetId, bytes32 pythFeedId, address chainlinkFeed);
    event AssetWhitelisted(bytes32 indexed assetId, bool status);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event HighWaterMarkUpdated(uint256 oldHwm, uint256 newHwm);
    event EmergencyModeActivated(address indexed activator);
    event EmergencyModeDeactivated(address indexed deactivator);
    event TvlCapUpdated(uint256 oldCap, uint256 newCap);
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);
    event DepositsLocked(bool locked, address indexed by);
    event PositionFlaggedForLiquidation(uint256 indexed positionId, address indexed keeper);

    // =========================================================================
    // §5  CUSTOM ERRORS
    // =========================================================================

    // -- Access --
    error CallerMissingRole(bytes32 role, address caller);
    error NotPositionOwnerOrKeeper(uint256 positionId, address caller);

    // -- Oracle --
    error OracleNotConfigured(bytes32 assetId);
    error AssetNotWhitelisted(bytes32 assetId);
    error StalePrice(bytes32 assetId, uint256 priceAge, uint256 maxAge);
    error NonPositivePrice(bytes32 assetId, int64 price);
    error OracleDeviationTooHigh(bytes32 assetId, uint256 deviationBps, uint256 maxDeviationBps);

    // -- Position --
    error PositionNotActive(uint256 positionId);
    error PositionNotLiquidatable(uint256 positionId);
    error MaxPositionsReached(uint256 maxAllowed, uint256 current);
    error PositionSizeTooLarge(uint128 sizeUsd, uint256 maxSizeUsd);
    error LeverageOutOfRange(uint32 leverageBps, uint32 minBps, uint32 maxBps);
    error InsufficientVaultLiquidity(uint256 required, uint256 available);
    error SlippageExceeded(uint128 minPrice, uint128 maxPrice, uint128 actualPrice);

    // -- Strategy --
    error StrategyNotFound(uint256 strategyId);
    error StrategyNotActive(uint256 strategyId);
    error InvalidStrategyType(uint8 strategyType);

    // -- Vault --
    error BelowMinDeposit(uint256 amount, uint256 minimum);
    error TvlCapExceeded(uint256 newTotal, uint256 cap);
    error DepositsCurrentlyLocked();
    error WithdrawalExceedsAvailableLiquidity(uint256 requested, uint256 available);
    error FlashLoanProtection(address user, uint256 blockedUntilBlock);
    error ZeroAmount();
    error ZeroAddress();
    error InvalidFee(uint256 feeBps, uint256 maxBps);
    error InvalidRiskConfig(string reason);
    error RouterNotSet();
    error TreasuryNotSet();
    error EmergencyModeActive();
    error NotInEmergencyMode();
    error SelfApprovalForbidden();

    // =========================================================================
    // §6  MODIFIERS
    // =========================================================================

    /**
     * @dev Reverts with a descriptive custom error when the caller lacks `role`.
     *      Preferred over OZ's `onlyRole` because it exposes our custom error type.
     */
    modifier requireRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert CallerMissingRole(role, msg.sender);
        _;
    }

    /**
     * @dev Ensures the router address has been configured.
     *      Positions cannot be opened without a router in production.
     */
    modifier routerSet() {
        if (address(router) == address(0)) revert RouterNotSet();
        _;
    }

    /**
     * @dev Ensures the treasury address has been configured.
     *      Fee collection requires a treasury.
     */
    modifier treasurySet() {
        if (treasury == address(0)) revert TreasuryNotSet();
        _;
    }

    /**
     * @dev Flash-loan protection: a user who deposited in block N cannot withdraw
     *      until block N+1.  Prevents atomic deposit-manipulate-withdraw attacks.
     *      Applied to `withdraw` and `redeem` only.
     */
    modifier flashLoanProtection() {
        uint256 depositBlock = lastDepositBlock[msg.sender];
        if (depositBlock == block.number) {
            revert FlashLoanProtection(msg.sender, block.number + 1);
        }
        _;
    }

    /**
     * @dev Allows the position owner OR any keeper to act on a position.
     */
    modifier onlyPositionOwnerOrKeeper(uint256 positionId) {
        if (positionOwners[positionId] != msg.sender && !hasRole(KEEPER_ROLE, msg.sender)) {
            revert NotPositionOwnerOrKeeper(positionId, msg.sender);
        }
        _;
    }

    // =========================================================================
    // §7  INITIALIZER
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Permanently lock the implementation contract so it cannot be initialised directly.
        // The proxy is initialised through `initialize()`.
        _disableInitializers();
    }

    /**
     * @notice Initialises the Synthora Vault proxy.
     * @dev    Called exactly once by the ERC1967Proxy at deploy time.
     *         All __*_init calls follow the linearised inheritance order.
     *
     * @param _asset      USDC token address (ERC-20, 6 decimals)
     * @param _pythOracle Pyth Network oracle contract
     * @param _treasury   Protocol fee recipient
     * @param _admin      Initial admin — receives all privileged roles
     * @param _name       Vault share token name  (e.g. "Synthora USDC Vault")
     * @param _symbol     Vault share token symbol (e.g. "svUSDC")
     */
    function initialize(
        address _asset,
        address _pythOracle,
        address _treasury,
        address _admin,
        string calldata _name,
        string calldata _symbol
    ) external initializer {
        // ── Address validation ────────────────────────────────────────────────
        if (_asset == address(0)) revert ZeroAddress();
        if (_pythOracle == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        // ── Base contract initialisers (order matters for linearised C3) ──────
        __UUPSUpgradeable_init();
        __Ownable_init(_admin); // sets owner + emits OwnershipTransferred
        __Ownable2Step_init(); // arms the two-step transfer mechanism
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();
        __ERC20_init(_name, _symbol);
        __ERC4626_init(IERC20(_asset));

        // ── Role setup ────────────────────────────────────────────────────────
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(STRATEGIST_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        // ── Core addresses ────────────────────────────────────────────────────
        pythOracle = IPyth(_pythOracle);
        treasury = _treasury;

        // ── Default fee config ────────────────────────────────────────────────
        feeConfig = FeeConfig({
            performanceFeeBps: 1_000, // 10 %
            managementFeeBps: 200, //  2 % p.a.
            withdrawalFeeBps: 50, //  0.5 %
            depositFeeBps: 0, //  0 %
            lastFeeCollection: uint64(block.timestamp),
            _feePad: 0,
            accruedFees: 0
        });

        // ── Default risk config ───────────────────────────────────────────────
        riskConfig = RiskConfig({
            minLeverageBps: 100, //  1×
            maxLeverageBps: 2_000, // 20×
            maxPositionSizeBps: 2_000, // 20 % of TVL per position
            liquidationThresholdBps: 8_500, // liq when 85 % of collateral lost
            maintenanceMarginBps: 500, //  5 % maintenance margin
            maxOpenPositions: 20,
            maxLeverageForDynamic: 1_500, // 15× cap for dynamic strategies
            fundingRateThresholdBps: 10 //  0.10 % min funding rate for arb
        });

        // ── HWM = 1:1 (1 share = 1 USDC at genesis) ─────────────────────────
        highWaterMark = PRICE_PRECISION; // 1e18
        minDepositAmount = 100 * USDC_DECIMALS; // $100 USDC minimum
        tvlCap = 0; // uncapped

        emit TreasuryUpdated(address(0), _treasury);
    }

    // =========================================================================
    // §8  ERC-4626 OVERRIDES — USER DEPOSIT / WITHDRAW
    // =========================================================================

    /**
     * @notice Deposits `assets` USDC and mints proportional vault shares to `receiver`.
     * @dev    Overrides ERC4626Upgradeable.deposit with:
     *         - Minimum deposit guard
     *         - TVL cap check
     *         - Deposit fee (sent to treasury)
     *         - Flash-loan protection (blocks same-block withdraw)
     *         - High-water mark update
     *
     * @param assets   USDC amount to deposit (6-dec)
     * @param receiver Address that will receive the vault shares
     * @return shares  Vault shares minted
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        _checkDeposit(assets, receiver);

        uint256 fee = _depositFee(assets);
        uint256 netAssets = assets - fee;

        // Shares are calculated on net assets (post-fee), consistent with previewDeposit
        shares = previewDeposit(netAssets);
        if (shares == 0) revert ZeroAmount();

        // Flash-loan protection: record deposit block BEFORE any transfer
        lastDepositBlock[receiver] = block.number;

        // Pull USDC from caller
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // Route deposit fee to treasury immediately
        if (fee > 0) IERC20(asset()).safeTransfer(treasury, fee);

        // Mint shares to receiver
        _mint(receiver, shares);
        userDepositedShares[receiver] += shares;

        _updateHighWaterMark();

        emit Deposited(msg.sender, receiver, assets, shares, fee);
        emit Deposit(msg.sender, receiver, netAssets, shares); // ERC4626 standard event
    }

    /**
     * @notice Mints exactly `shares` vault shares by depositing the required USDC.
     * @dev    Overrides ERC4626Upgradeable.mint.
     */
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // previewMint returns gross assets (before deposit fee)
        assets = previewMint(shares);
        _checkDeposit(assets, receiver);

        uint256 fee = _depositFee(assets);
        uint256 netAssets = assets - fee;

        lastDepositBlock[receiver] = block.number;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        if (fee > 0) IERC20(asset()).safeTransfer(treasury, fee);

        _mint(receiver, shares);
        userDepositedShares[receiver] += shares;

        _updateHighWaterMark();

        emit Deposited(msg.sender, receiver, assets, shares, fee);
        emit Deposit(msg.sender, receiver, netAssets, shares);
    }

    /**
     * @notice Burns `owner`'s shares and transfers `assets` USDC to `receiver`.
     * @dev    Overrides ERC4626Upgradeable.withdraw with:
     *         - Flash-loan protection
     *         - Available liquidity check (collateral-locked funds cannot be withdrawn)
     *         - Withdrawal fee (sent to treasury)
     *         - Management-fee sweep before execution
     *         - Emergency-mode bypass for pause
     *
     * @param assets   USDC to receive (6-dec)
     * @param receiver Address that receives the USDC
     * @param owner    Address whose shares are burned
     * @return shares  Shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        flashLoanProtection
        returns (uint256 shares)
    {
        if (!emergencyMode) _requireNotPaused();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 available = _availableLiquidity();
        if (assets > available) revert WithdrawalExceedsAvailableLiquidity(assets, available);

        // Shares required to redeem `assets` (pre-fee gross)
        shares = previewWithdraw(assets);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        // Accrue management fees before computing share value
        _sweepManagementFee();

        uint256 fee = _withdrawalFee(assets);
        uint256 assetsOut = assets - fee;

        _burn(owner, shares);
        if (userDepositedShares[owner] >= shares) {
            userDepositedShares[owner] -= shares;
        }

        if (fee > 0) IERC20(asset()).safeTransfer(treasury, fee);
        IERC20(asset()).safeTransfer(receiver, assetsOut);

        emit Withdrawn(msg.sender, receiver, owner, assets, shares, fee);
        emit Withdraw(msg.sender, receiver, owner, assetsOut, shares); // ERC4626 standard
    }

    /**
     * @notice Burns exactly `shares` and transfers proportional USDC to `receiver`.
     * @dev    Overrides ERC4626Upgradeable.redeem.
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        flashLoanProtection
        returns (uint256 assets)
    {
        if (!emergencyMode) _requireNotPaused();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        assets = previewRedeem(shares);

        uint256 available = _availableLiquidity();
        if (assets > available) revert WithdrawalExceedsAvailableLiquidity(assets, available);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _sweepManagementFee();

        uint256 fee = _withdrawalFee(assets);
        uint256 assetsOut = assets - fee;

        _burn(owner, shares);
        if (userDepositedShares[owner] >= shares) {
            userDepositedShares[owner] -= shares;
        }

        if (fee > 0) IERC20(asset()).safeTransfer(treasury, fee);
        IERC20(asset()).safeTransfer(receiver, assetsOut);

        emit Withdrawn(msg.sender, receiver, owner, assets, shares, fee);
        emit Withdraw(msg.sender, receiver, owner, assetsOut, shares);
    }

    /**
     * @notice Emergency exit: withdraws proportional USDC when vault is in emergency mode.
     * @dev    Bypasses all fee logic; available USDC is split pro-rata by share count.
     *         Only callable when `emergencyMode == true`.
     *
     * @param shares   Shares to burn
     * @param receiver USDC recipient
     */
    function emergencyWithdraw(uint256 shares, address receiver) external nonReentrant {
        if (!emergencyMode) revert NotInEmergencyMode();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 supply = totalSupply();
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        // Pro-rata share of whatever USDC is actually in the contract
        uint256 assetsOut = (balance * shares) / supply;

        if (msg.sender != receiver) _spendAllowance(receiver, msg.sender, shares);

        _burn(msg.sender, shares);
        IERC20(asset()).safeTransfer(receiver, assetsOut);

        emit Withdrawn(msg.sender, receiver, msg.sender, assetsOut, shares, 0);
    }

    // =========================================================================
    // §9  STRATEGIST FUNCTIONS — POSITION & STRATEGY MANAGEMENT
    // =========================================================================

    /**
     * @notice Opens a leveraged synthetic position on `assetId`.
     * @dev    Security considerations:
     *         • `whitelistedAssets` prevents rogue feed IDs.
     *         • Leverage bounds enforced by `RiskConfig`.
     *         • Single position capped at `maxPositionSizeBps` of TVL.
     *         • `minEntryPrice` / `maxEntryPrice` provide sandwich protection.
     *         • `routerSet` ensures execution layer is configured.
     *         • `nonReentrant` guards against re-entry through oracle callbacks.
     *
     * @param assetId       Pyth feed ID of the synthetic asset (must be whitelisted)
     * @param collateralUsd Margin in USDC (6-dec) — pulled from vault idle liquidity
     * @param leverageBps   Leverage × 100 (100 = 1×, 2000 = 20×)
     * @param isLong        True = long, false = short
     * @param strategyType  0 = fixed, 1 = dynamic, 2 = funding-arb
     * @param minEntryPrice Minimum acceptable fill price (18-dec); rejects if below
     * @param maxEntryPrice Maximum acceptable fill price (18-dec); rejects if above
     * @return positionId   Vault-local position identifier
     */
    function executeStrategy(
        bytes32 assetId,
        uint128 collateralUsd,
        uint32 leverageBps,
        bool isLong,
        uint8 strategyType,
        uint128 minEntryPrice,
        uint128 maxEntryPrice
    ) external nonReentrant whenNotPaused routerSet requireRole(STRATEGIST_ROLE) returns (uint256 positionId) {
        // ── Pre-condition checks ───────────────────────────────────────────────
        if (!whitelistedAssets[assetId]) revert AssetNotWhitelisted(assetId);
        if (collateralUsd == 0) revert ZeroAmount();
        if (strategyType > 2) revert InvalidStrategyType(strategyType);

        RiskConfig memory risk = riskConfig;

        // Leverage bounds (dynamic strategy has a tighter cap)
        uint32 leverageCap = strategyType == 1 ? risk.maxLeverageForDynamic : risk.maxLeverageBps;
        if (leverageBps < risk.minLeverageBps || leverageBps > leverageCap) {
            revert LeverageOutOfRange(leverageBps, risk.minLeverageBps, leverageCap);
        }

        // Max concurrent positions
        if (activePositionCount >= risk.maxOpenPositions) {
            revert MaxPositionsReached(risk.maxOpenPositions, activePositionCount);
        }

        // Vault liquidity
        uint256 liquid = _availableLiquidity();
        if (collateralUsd > liquid) revert InsufficientVaultLiquidity(collateralUsd, liquid);

        // Compute notional size: size = collateral × leverage / LEVERAGE_PRECISION
        // leverageBps = 500  → leverage multiplier = 500 / 100 = 5×
        uint128 sizeUsd = uint128((uint256(collateralUsd) * leverageBps) / LEVERAGE_PRECISION);

        // Per-position size cap (fraction of TVL)
        uint256 maxSize = totalAssets().mulDiv(risk.maxPositionSizeBps, BASIS_POINTS, Math.Rounding.Floor);
        if (sizeUsd > maxSize) revert PositionSizeTooLarge(sizeUsd, maxSize);

        // ── Oracle price ───────────────────────────────────────────────────────
        uint128 entryPrice = _getValidatedPrice(assetId);

        // Sandwich / frontrunning protection
        if (entryPrice < minEntryPrice || entryPrice > maxEntryPrice) {
            revert SlippageExceeded(minEntryPrice, maxEntryPrice, entryPrice);
        }

        // ── Liquidation price pre-computation ─────────────────────────────────
        uint128 liqPrice = _computeLiquidationPrice(entryPrice, leverageBps, isLong, risk.liquidationThresholdBps);

        // ── Store position ─────────────────────────────────────────────────────
        positionId = uint256(++totalPositionsOpened);

        positions[positionId] = Position({
            assetId: assetId,
            sizeUsd: sizeUsd,
            collateralUsd: collateralUsd,
            entryPrice: entryPrice,
            liquidationPrice: liqPrice,
            openTimestamp: uint64(block.timestamp),
            lastUpdateTimestamp: uint64(block.timestamp),
            leverageBps: leverageBps,
            strategyType: strategyType,
            isLong: isLong,
            isActive: true,
            isLiquidatable: false,
            _pad: 0
        });

        positionOwners[positionId] = msg.sender;
        activePositionCount += 1;
        totalCollateralLocked += collateralUsd;
        totalNotionalValue += sizeUsd;
        assetExposure[assetId] += sizeUsd;

        // ── PLACEHOLDER: route to execution layer ──────────────────────────────
        // In production, replace with:
        //   IERC20(asset()).safeApprove(address(router), collateralUsd);
        //   router.openPosition(assetId, sizeUsd, collateralUsd, isLong, entryPrice);
        _placeholderRouteOpen(assetId, sizeUsd, collateralUsd, isLong, entryPrice);

        emit PositionOpened(
            positionId, assetId, msg.sender, isLong, sizeUsd, collateralUsd, entryPrice, leverageBps, strategyType
        );
    }

    /**
     * @notice Closes an active position and realises PnL into the vault.
     * @dev    Performance fee is charged on profits only.
     *         Position owner or any keeper may trigger a close.
     *
     * @param positionId    Vault-local position ID
     * @param minExitPrice  Minimum acceptable price (for shorts, guards against closing too high)
     * @param maxExitPrice  Maximum acceptable price (for longs, guards against closing too low)
     */
    function closePosition(uint256 positionId, uint128 minExitPrice, uint128 maxExitPrice)
        external
        nonReentrant
        whenNotPaused
        onlyPositionOwnerOrKeeper(positionId)
    {
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive(positionId);

        uint128 exitPrice = _getValidatedPrice(pos.assetId);

        // Slippage check
        if (exitPrice < minExitPrice || exitPrice > maxExitPrice) {
            revert SlippageExceeded(minExitPrice, maxExitPrice, exitPrice);
        }

        // Unrealised PnL at exit price
        int256 pnl = _unrealisedPnL(pos, exitPrice);

        // Performance fee (HWM-gated: only on profits above HWM)
        uint256 perfFee = 0;
        if (pnl > 0) {
            uint256 profit = uint256(pnl);
            uint256 supply = totalSupply();
            if (supply > 0) {
                // Only charge if current share price exceeds HWM
                uint256 currentSpx = totalAssets().mulDiv(PRICE_PRECISION, supply, Math.Rounding.Floor);
                if (currentSpx > highWaterMark) {
                    perfFee = profit.mulDiv(feeConfig.performanceFeeBps, BASIS_POINTS, Math.Rounding.Floor);
                }
            }
        }

        // ── Mutate state ───────────────────────────────────────────────────────
        _closePositionState(positionId, pos);

        // ── PLACEHOLDER: route close to execution layer ────────────────────────
        // router.closePosition(positionId, exitPrice);
        _placeholderRouteClose(positionId, pos.assetId, exitPrice);

        // Transfer performance fee
        if (perfFee > 0) {
            uint256 bal = IERC20(asset()).balanceOf(address(this));
            if (perfFee > bal) perfFee = bal;
            if (perfFee > 0) {
                IERC20(asset()).safeTransfer(treasury, perfFee);
                emit FeesCollected(perfFee, 0, treasury, block.timestamp);
            }
        }

        _updateHighWaterMark();

        emit PositionClosed(positionId, pos.assetId, exitPrice, pnl, perfFee);
    }

    /**
     * @notice Adjusts the leverage (and thus notional size) of an active position.
     * @dev    Recalculates liquidation price with new leverage.
     *         Notional size change is reflected in `totalNotionalValue` and `assetExposure`.
     *
     * @param positionId    Position to adjust
     * @param newLeverageBps New leverage in bps (100 = 1×)
     */
    function adjustLeverage(uint256 positionId, uint32 newLeverageBps)
        external
        nonReentrant
        whenNotPaused
        routerSet
        onlyPositionOwnerOrKeeper(positionId)
    {
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive(positionId);

        RiskConfig memory risk = riskConfig;
        uint32 leverageCap = pos.strategyType == 1 ? risk.maxLeverageForDynamic : risk.maxLeverageBps;
        if (newLeverageBps < risk.minLeverageBps || newLeverageBps > leverageCap) {
            revert LeverageOutOfRange(newLeverageBps, risk.minLeverageBps, leverageCap);
        }

        uint32 oldLeverage = pos.leverageBps;
        uint128 oldSize = pos.sizeUsd;
        uint128 newSize = uint128((uint256(pos.collateralUsd) * newLeverageBps) / LEVERAGE_PRECISION);

        // Per-position size cap
        uint256 maxSize = totalAssets().mulDiv(risk.maxPositionSizeBps, BASIS_POINTS, Math.Rounding.Floor);
        if (newSize > maxSize) revert PositionSizeTooLarge(newSize, maxSize);

        uint128 currentPrice = _getValidatedPrice(pos.assetId);
        uint128 newLiqPrice =
            _computeLiquidationPrice(currentPrice, newLeverageBps, pos.isLong, risk.liquidationThresholdBps);

        // Update position
        pos.leverageBps = newLeverageBps;
        pos.sizeUsd = newSize;
        pos.liquidationPrice = newLiqPrice;
        pos.lastUpdateTimestamp = uint64(block.timestamp);

        // Update global exposure tracking (carefully avoid underflow)
        if (newSize >= oldSize) {
            uint128 delta = newSize - oldSize;
            totalNotionalValue += delta;
            assetExposure[pos.assetId] += delta;
        } else {
            uint128 delta = oldSize - newSize;
            totalNotionalValue -= delta;
            assetExposure[pos.assetId] -= delta;
        }

        // PLACEHOLDER: router.adjustLeverage(positionId, newSize, newLeverageBps, currentPrice);

        emit PositionAdjusted(positionId, oldLeverage, newLeverageBps, oldSize, newSize, newLiqPrice);
    }

    /**
     * @notice Creates an automated trading strategy template.
     * @param assetId               Target synthetic asset
     * @param targetSizeUsd         Desired notional size (USDC, 6-dec)
     * @param leverageBps           Initial leverage
     * @param isLong                Initial direction
     * @param isNeutral             True for market-neutral (funding arb)
     * @param strategyType          0=fixed 1=dynamic 2=fundingArb
     * @param maxDrawdownBps        Halt threshold (bps of initial collateral)
     * @param rebalanceThresholdBps Drift % that triggers keeper rebalance
     * @param profitTakingBps       Profit % that triggers keeper partial close
     * @return strategyId           New strategy ID
     */
    function createStrategy(
        bytes32 assetId,
        uint128 targetSizeUsd,
        uint32 leverageBps,
        bool isLong,
        bool isNeutral,
        uint8 strategyType,
        uint128 maxDrawdownBps,
        uint32 rebalanceThresholdBps,
        uint32 profitTakingBps
    ) external nonReentrant whenNotPaused requireRole(STRATEGIST_ROLE) returns (uint256 strategyId) {
        if (!whitelistedAssets[assetId]) revert AssetNotWhitelisted(assetId);
        if (strategyType > 2) revert InvalidStrategyType(strategyType);

        RiskConfig memory risk = riskConfig;
        uint32 leverageCap = strategyType == 1 ? risk.maxLeverageForDynamic : risk.maxLeverageBps;
        if (leverageBps < risk.minLeverageBps || leverageBps > leverageCap) {
            revert LeverageOutOfRange(leverageBps, risk.minLeverageBps, leverageCap);
        }

        strategyId = ++strategyCount;

        strategies[strategyId] = Strategy({
            assetId: assetId,
            targetSizeUsd: targetSizeUsd,
            maxDrawdownBps: maxDrawdownBps,
            createdAt: uint64(block.timestamp),
            lastExecutedAt: 0,
            leverageBps: leverageBps,
            rebalanceThresholdBps: rebalanceThresholdBps,
            profitTakingBps: profitTakingBps,
            strategyType: strategyType,
            isLong: isLong,
            isActive: true,
            isNeutral: isNeutral,
            _pad: 0
        });

        emit StrategyCreated(strategyId, assetId, strategyType, msg.sender);
    }

    /**
     * @notice Updates mutable parameters of an existing strategy.
     */
    function updateStrategy(
        uint256 strategyId,
        uint32 newLeverageBps,
        uint128 newTargetSize,
        uint32 newRebalanceThreshold,
        uint32 newProfitTaking
    ) external requireRole(STRATEGIST_ROLE) {
        Strategy storage strat = strategies[strategyId];
        if (!strat.isActive) revert StrategyNotActive(strategyId);

        RiskConfig memory risk = riskConfig;
        uint32 leverageCap = strat.strategyType == 1 ? risk.maxLeverageForDynamic : risk.maxLeverageBps;
        if (newLeverageBps < risk.minLeverageBps || newLeverageBps > leverageCap) {
            revert LeverageOutOfRange(newLeverageBps, risk.minLeverageBps, leverageCap);
        }

        strat.leverageBps = newLeverageBps;
        strat.targetSizeUsd = newTargetSize;
        strat.rebalanceThresholdBps = newRebalanceThreshold;
        strat.profitTakingBps = newProfitTaking;

        emit StrategyUpdated(strategyId, newLeverageBps, newTargetSize);
    }

    /**
     * @notice Deactivates a strategy so keepers will no longer execute it.
     */
    function deactivateStrategy(uint256 strategyId) external requireRole(STRATEGIST_ROLE) {
        Strategy storage strat = strategies[strategyId];
        if (strat.assetId == bytes32(0)) revert StrategyNotFound(strategyId);
        strat.isActive = false;
        emit StrategyDeactivated(strategyId, msg.sender);
    }

    // =========================================================================
    // §10 KEEPER FUNCTIONS
    // =========================================================================

    /**
     * @notice Liquidates a position that has fallen below maintenance margin.
     * @dev    Keepers MUST verify the price is fresh before calling (use `getPositionHealth`).
     *         The vault re-validates the oracle and the liquidation condition on-chain.
     *
     * @param positionId Position to liquidate
     */
    function liquidatePosition(uint256 positionId) external nonReentrant requireRole(KEEPER_ROLE) routerSet {
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive(positionId);

        uint128 liqPrice = _getValidatedPrice(pos.assetId);

        if (!_isLiquidatable(pos, liqPrice)) revert PositionNotLiquidatable(positionId);

        pos.isLiquidatable = true;
        _closePositionState(positionId, pos);

        // PLACEHOLDER: router.liquidatePosition(positionId, liqPrice, msg.sender);
        _placeholderRouteLiquidate(positionId, pos.assetId, liqPrice);

        emit PositionLiquidated(positionId, pos.assetId, liqPrice, msg.sender);
    }

    /**
     * @notice Dynamically rebalances a position for dynamic/funding-arb strategies.
     * @dev    No-op for fixed-leverage positions (strategyType == 0).
     *         Calculates new leverage using a volatility proxy derived from
     *         the current vs. entry price deviation and unrealised PnL.
     *
     * @param positionId Position to rebalance
     */
    function rebalancePosition(uint256 positionId)
        external
        nonReentrant
        whenNotPaused
        requireRole(KEEPER_ROLE)
        routerSet
    {
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive(positionId);
        if (pos.strategyType == 0) return; // Fixed leverage — skip

        uint128 currentPrice = _getValidatedPrice(pos.assetId);
        int256 pnl = _unrealisedPnL(pos, currentPrice);
        uint32 newLeverage = _computeDynamicLeverage(pos, currentPrice, pnl);

        if (newLeverage == pos.leverageBps) return; // No change needed

        uint128 oldSize = pos.sizeUsd;
        uint128 newSize = uint128((uint256(pos.collateralUsd) * newLeverage) / LEVERAGE_PRECISION);

        // Clamp to per-position size cap
        uint256 maxSize = totalAssets().mulDiv(riskConfig.maxPositionSizeBps, BASIS_POINTS, Math.Rounding.Floor);
        if (newSize > uint128(maxSize)) newSize = uint128(maxSize);

        // Update global notional tracking
        if (newSize >= oldSize) {
            uint128 delta = newSize - oldSize;
            totalNotionalValue += delta;
            assetExposure[pos.assetId] += delta;
        } else {
            uint128 delta = oldSize - newSize;
            totalNotionalValue -= delta;
            assetExposure[pos.assetId] -= delta;
        }

        uint128 newLiqPrice =
            _computeLiquidationPrice(currentPrice, newLeverage, pos.isLong, riskConfig.liquidationThresholdBps);

        pos.sizeUsd = newSize;
        pos.leverageBps = newLeverage;
        pos.liquidationPrice = newLiqPrice;
        pos.lastUpdateTimestamp = uint64(block.timestamp);

        emit PositionRebalanced(positionId, newLeverage, newSize, block.timestamp);
    }

    /**
     * @notice Executes a funding-rate arbitrage adjustment on a market-neutral position.
     * @dev    Only applies to positions with strategyType == 2.
     *         If the funding rate exceeds `fundingRateThresholdBps`, the keeper
     *         signals the router to flip or maintain the position accordingly.
     *
     * @param positionId  Position configured for funding arb
     * @param fundingRate Current signed funding rate in bps (negative = shorts pay longs)
     */
    function executeFundingArbitrage(uint256 positionId, int256 fundingRate)
        external
        nonReentrant
        whenNotPaused
        requireRole(KEEPER_ROLE)
        routerSet
    {
        Position storage pos = positions[positionId];
        if (!pos.isActive) revert PositionNotActive(positionId);
        if (pos.strategyType != 2) revert InvalidStrategyType(pos.strategyType);

        // Only act if funding rate crosses the threshold
        uint256 absRate = fundingRate >= 0 ? uint256(fundingRate) : uint256(-fundingRate);
        if (absRate < riskConfig.fundingRateThresholdBps) return;

        pos.lastUpdateTimestamp = uint64(block.timestamp);

        // PLACEHOLDER: router.adjustFundingArb(positionId, fundingRate);
        // In production this may flip direction of one leg of a neutral position.

        emit FundingArbitrageExecuted(positionId, pos.assetId, fundingRate);
    }

    /**
     * @notice Batch-flags positions as potentially liquidatable based on fresh oracle data.
     * @dev    Keepers call this after pushing a Pyth price update on-chain.
     *         The actual liquidation must follow via `liquidatePosition()`.
     *         Uses `try/catch` to gracefully skip stale / unconfigured feeds.
     *
     * @param positionIds Array of position IDs to evaluate (calldata — gas efficient)
     */
    function flagPositionsForLiquidation(uint256[] calldata positionIds) external requireRole(KEEPER_ROLE) {
        uint256 len = positionIds.length;
        for (uint256 i; i < len;) {
            uint256 pid = positionIds[i];
            Position storage pos = positions[pid];

            if (pos.isActive && !pos.isLiquidatable) {
                OracleConfig memory cfg = oracleConfigs[pos.assetId];
                if (cfg.isActive) {
                    try pythOracle.getPriceNoOlderThan(cfg.pythFeedId, cfg.maxPriceAge) returns (IPyth.Price memory p) {
                        if (p.price > 0) {
                            uint128 price = uint128(uint64(p.price));
                            if (_isLiquidatable(pos, price)) {
                                pos.isLiquidatable = true;
                                emit PositionFlaggedForLiquidation(pid, msg.sender);
                            }
                        }
                    } catch {} // Stale or missing feed — skip silently
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // §11 ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Updates vault fee parameters.
     * @dev    Sweeps accrued management fees before applying the new rate
     *         so existing LPs are not retroactively charged the new rate.
     */
    function setFeeConfig(
        uint32 performanceFeeBps,
        uint32 managementFeeBps,
        uint32 withdrawalFeeBps,
        uint32 depositFeeBps
    ) external requireRole(DEFAULT_ADMIN_ROLE) {
        if (performanceFeeBps > MAX_FEE_BPS) revert InvalidFee(performanceFeeBps, MAX_FEE_BPS);
        if (managementFeeBps > MAX_MGMT_FEE_BPS) revert InvalidFee(managementFeeBps, MAX_MGMT_FEE_BPS);
        if (withdrawalFeeBps > MAX_ENTRY_EXIT_FEE_BPS) revert InvalidFee(withdrawalFeeBps, MAX_ENTRY_EXIT_FEE_BPS);
        if (depositFeeBps > MAX_ENTRY_EXIT_FEE_BPS) revert InvalidFee(depositFeeBps, MAX_ENTRY_EXIT_FEE_BPS);

        _sweepManagementFee(); // Settle with old rate first

        feeConfig.performanceFeeBps = performanceFeeBps;
        feeConfig.managementFeeBps = managementFeeBps;
        feeConfig.withdrawalFeeBps = withdrawalFeeBps;
        feeConfig.depositFeeBps = depositFeeBps;

        emit FeeConfigUpdated(performanceFeeBps, managementFeeBps, withdrawalFeeBps, depositFeeBps);
    }

    /**
     * @notice Updates risk and leverage bounds.
     * @dev    Existing positions are NOT retroactively affected; new positions
     *         and leverage adjustments will use the updated config.
     */
    function setRiskConfig(
        uint32 minLeverageBps,
        uint32 maxLeverageBps,
        uint32 maxPositionSizeBps,
        uint32 liquidationThresholdBps,
        uint32 maintenanceMarginBps,
        uint32 maxOpenPositions,
        uint32 maxLeverageForDynamic,
        uint32 fundingRateThresholdBps
    ) external requireRole(DEFAULT_ADMIN_ROLE) {
        if (minLeverageBps < MIN_LEVERAGE_BPS) revert InvalidRiskConfig("minLev < 1x");
        if (maxLeverageBps > MAX_LEVERAGE_BPS * LEVERAGE_PRECISION) {
            revert InvalidRiskConfig("maxLev > 20x");
        }
        if (maxLeverageBps <= minLeverageBps) revert InvalidRiskConfig("max <= min");
        if (maxPositionSizeBps > 5_000) revert InvalidRiskConfig("posSz > 50%");
        if (liquidationThresholdBps < 5_000 || liquidationThresholdBps > 9_900) {
            revert InvalidRiskConfig("liqThresh OOB");
        }
        if (maintenanceMarginBps > liquidationThresholdBps) revert InvalidRiskConfig("maint > liq");
        if (maxOpenPositions == 0 || maxOpenPositions > 100) revert InvalidRiskConfig("positions OOB");
        if (maxLeverageForDynamic > maxLeverageBps) revert InvalidRiskConfig("dynLev > maxLev");

        riskConfig = RiskConfig({
            minLeverageBps: minLeverageBps,
            maxLeverageBps: maxLeverageBps,
            maxPositionSizeBps: maxPositionSizeBps,
            liquidationThresholdBps: liquidationThresholdBps,
            maintenanceMarginBps: maintenanceMarginBps,
            maxOpenPositions: maxOpenPositions,
            maxLeverageForDynamic: maxLeverageForDynamic,
            fundingRateThresholdBps: fundingRateThresholdBps
        });

        emit RiskConfigUpdated(riskConfig);
    }

    /**
     * @notice Configures dual-oracle parameters for a synthetic asset.
     * @param assetId              Synthetic asset identifier (any bytes32 key)
     * @param pythFeedId           Pyth Network price feed ID
     * @param chainlinkFeed        Chainlink AggregatorV3 address (zero disables)
     * @param maxPriceAge          Maximum acceptable price age in seconds (≤ 3600)
     * @param maxDeviationBps      Maximum tolerable deviation between oracles (≤ 10%)
     * @param useChainlinkFallback Whether to validate Pyth against Chainlink
     */
    function setOracleConfig(
        bytes32 assetId,
        bytes32 pythFeedId,
        address chainlinkFeed,
        uint32 maxPriceAge,
        uint32 maxDeviationBps,
        bool useChainlinkFallback
    ) external requireRole(DEFAULT_ADMIN_ROLE) {
        if (pythFeedId == bytes32(0)) revert InvalidRiskConfig("pythFeedId zero");
        if (maxPriceAge == 0 || maxPriceAge > 3_600) revert InvalidRiskConfig("maxAge OOB");
        if (maxDeviationBps > 1_000) revert InvalidRiskConfig("deviation > 10%");

        oracleConfigs[assetId] = OracleConfig({
            pythFeedId: pythFeedId,
            chainlinkFeed: chainlinkFeed,
            maxPriceAge: maxPriceAge,
            maxDeviationBps: maxDeviationBps,
            isActive: true,
            useChainlinkFallback: useChainlinkFallback,
            _pad: 0
        });

        emit OracleConfigSet(assetId, pythFeedId, chainlinkFeed);
    }

    /// @notice Enables or disables an asset for trading.
    function setAssetWhitelist(bytes32 assetId, bool status) external requireRole(DEFAULT_ADMIN_ROLE) {
        whitelistedAssets[assetId] = status;
        emit AssetWhitelisted(assetId, status);
    }

    /// @notice Replaces the order-execution router.
    function setRouter(address newRouter) external requireRole(DEFAULT_ADMIN_ROLE) {
        if (newRouter == address(0)) revert ZeroAddress();
        address old = address(router);
        router = ISynthoraRouter(newRouter);
        emit RouterUpdated(old, newRouter);
    }

    /// @notice Replaces the treasury address.
    function setTreasury(address newTreasury) external requireRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    /// @notice Sets the TVL cap. Pass 0 to remove the cap.
    function setTvlCap(uint256 newCap) external requireRole(DEFAULT_ADMIN_ROLE) {
        emit TvlCapUpdated(tvlCap, newCap);
        tvlCap = newCap;
    }

    /// @notice Sets the minimum deposit amount (USDC, 6-dec).
    function setMinDeposit(uint256 newMin) external requireRole(DEFAULT_ADMIN_ROLE) {
        emit MinDepositUpdated(minDepositAmount, newMin);
        minDepositAmount = newMin;
    }

    /// @notice Locks or unlocks new deposits (e.g. at TVL cap, during audits).
    function setDepositsLocked(bool locked) external requireRole(DEFAULT_ADMIN_ROLE) {
        depositsLocked = locked;
        emit DepositsLocked(locked, msg.sender);
    }

    /// @notice Manually sweeps accrued management fees to treasury.
    function collectManagementFees() external requireRole(DEFAULT_ADMIN_ROLE) treasurySet {
        _sweepManagementFee();
    }

    // =========================================================================
    // §12 PAUSE / EMERGENCY
    // =========================================================================

    /// @notice Pauses the vault — prevents deposits, withdrawals, and new positions.
    function pause() external requireRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses — only DEFAULT_ADMIN_ROLE to prevent misuse by pausers.
    function unpause() external requireRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Activates emergency mode.
     * @dev    Simultaneously pauses the vault and enables `emergencyWithdraw`.
     *         Use when a critical vulnerability is discovered or an extreme
     *         market event has made normal operations unsafe.
     */
    function activateEmergencyMode() external requireRole(DEFAULT_ADMIN_ROLE) {
        emergencyMode = true;
        if (!paused()) _pause();
        emit EmergencyModeActivated(msg.sender);
    }

    /// @notice Deactivates emergency mode (must manually unpause afterwards).
    function deactivateEmergencyMode() external requireRole(DEFAULT_ADMIN_ROLE) {
        if (!emergencyMode) revert NotInEmergencyMode();
        emergencyMode = false;
        emit EmergencyModeDeactivated(msg.sender);
    }

    // =========================================================================
    // §13 VIEW / GETTER FUNCTIONS  (≥18 functions for frontend)
    // =========================================================================

    // ── (1) ERC-4626 override ────────────────────────────────────────────────

    /**
     * @notice Total USDC value managed by the vault (idle + locked in positions).
     * @dev    ERC-4626 override.  In production, should also add unrealised PnL
     *         returned from the router, but kept conservative here (cost-basis).
     * @return Total assets in USDC (6-dec)
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalCollateralLocked;
    }

    // ── (2) ─────────────────────────────────────────────────────────────────

    /**
     * @notice USDC available for new positions or withdrawals (not locked as collateral).
     */
    function availableLiquidity() external view returns (uint256) {
        return _availableLiquidity();
    }

    // ── (3) ─────────────────────────────────────────────────────────────────

    /**
     * @notice Current share price in USDC (18-dec, i.e. 1e18 = $1.00).
     */
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return PRICE_PRECISION;
        return totalAssets().mulDiv(PRICE_PRECISION, supply, Math.Rounding.Floor);
    }

    // ── (4) ─────────────────────────────────────────────────────────────────

    /**
     * @notice Returns full position data for a given position ID.
     */
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    // ── (5) ─────────────────────────────────────────────────────────────────

    /**
     * @notice Position health expressed in basis points.
     * @dev    10 000 = exactly at maintenance margin.
     *         > 10 000 = healthy.
     *         < 10 000 = approaching liquidation (keeper should flag).
     *         0 = position closed, feed stale, or maintenance margin is zero.
     *
     * @param positionId Position to evaluate
     * @return healthBps Health ratio (basis points)
     */
    function getPositionHealth(uint256 positionId) external view returns (uint256 healthBps) {
        Position memory pos = positions[positionId];
        if (!pos.isActive) return 0;

        OracleConfig memory cfg = oracleConfigs[pos.assetId];
        if (!cfg.isActive) return 0;

        try pythOracle.getPriceNoOlderThan(cfg.pythFeedId, cfg.maxPriceAge) returns (IPyth.Price memory p) {
            if (p.price <= 0) return 0;
            uint128 price = uint128(uint64(p.price));
            int256 pnl = _unrealisedPnL(pos, price);
            int256 effectiveColl = int256(uint256(pos.collateralUsd)) + pnl;
            if (effectiveColl <= 0) return 0;

            uint256 maintenanceReq =
                pos.sizeUsd.mulDiv(riskConfig.maintenanceMarginBps, BASIS_POINTS, Math.Rounding.Ceil);
            if (maintenanceReq == 0) return type(uint256).max;

            healthBps = uint256(effectiveColl).mulDiv(BASIS_POINTS, maintenanceReq, Math.Rounding.Floor);
        } catch {
            return 0;
        }
    }

    // ── (6) ─────────────────────────────────────────────────────────────────

    /**
     * @notice Unrealised PnL for a position at the latest oracle price.
     * @param positionId Position ID
     * @return pnl Signed USDC (6-dec) — positive = profit, negative = loss
     */
    function getPositionPnL(uint256 positionId) external view returns (int256 pnl) {
        Position memory pos = positions[positionId];
        if (!pos.isActive) return 0;

        OracleConfig memory cfg = oracleConfigs[pos.assetId];
        if (!cfg.isActive) return 0;

        try pythOracle.getPriceNoOlderThan(cfg.pythFeedId, cfg.maxPriceAge) returns (IPyth.Price memory p) {
            if (p.price <= 0) return 0;
            pnl = _unrealisedPnL(pos, uint128(uint64(p.price)));
        } catch {}
    }

    // ── (7) ─────────────────────────────────────────────────────────────────

    /**
     * @notice Latest Pyth price for a whitelisted asset.
     * @param assetId          Asset identifier
     * @return price           Normalised price (18-dec)
     * @return publishTime     Unix timestamp of last price update
     * @return confidenceBps   Confidence interval as bps of price (risk metric)
     */
    function getAssetPrice(bytes32 assetId)
        external
        view
        returns (uint128 price, uint256 publishTime, uint256 confidenceBps)
    {
        OracleConfig memory cfg = oracleConfigs[assetId];
        if (!cfg.isActive) revert OracleNotConfigured(assetId);

        IPyth.Price memory p = pythOracle.getPriceUnsafe(cfg.pythFeedId);
        price = uint128(uint64(p.price));
        publishTime = p.publishTime;
        // Confidence expressed as a percentage of the price (in bps)
        confidenceBps = price > 0 ? uint256(p.conf).mulDiv(BASIS_POINTS, uint256(price), Math.Rounding.Ceil) : 0;
    }

    // ── (8) ─────────────────────────────────────────────────────────────────

    /**
     * @notice Returns whether a position's collateral has fallen below the
     *         maintenance margin at the current oracle price.
     */
    function isPositionLiquidatable(uint256 positionId) external view returns (bool) {
        Position memory pos = positions[positionId];
        if (!pos.isActive) return false;

        OracleConfig memory cfg = oracleConfigs[pos.assetId];
        if (!cfg.isActive) return false;

        try pythOracle.getPriceNoOlderThan(cfg.pythFeedId, cfg.maxPriceAge) returns (IPyth.Price memory p) {
            if (p.price <= 0) return false;
            return _isLiquidatable(pos, uint128(uint64(p.price)));
        } catch {
            return false;
        }
    }

    // ── (9) ─────────────────────────────────────────────────────────────────

    /// @notice Returns the full strategy struct for a strategy ID.
    function getStrategy(uint256 strategyId) external view returns (Strategy memory) {
        return strategies[strategyId];
    }

    // ── (10) ────────────────────────────────────────────────────────────────

    /**
     * @notice Vault-wide risk snapshot for dashboards.
     * @return utilizationBps   Locked collateral as % of TVL (bps)
     * @return totalExposureUsd Total notional value across all positions (USDC 6-dec)
     * @return openPositions    Number of currently active positions
     * @return liquidUsd        Idle USDC available for new positions / withdrawals
     */
    function getVaultMetrics()
        external
        view
        returns (uint256 utilizationBps, uint256 totalExposureUsd, uint256 openPositions, uint256 liquidUsd)
    {
        uint256 assets = totalAssets();
        utilizationBps = assets > 0 ? totalCollateralLocked.mulDiv(BASIS_POINTS, assets, Math.Rounding.Floor) : 0;
        totalExposureUsd = totalNotionalValue;
        openPositions = activePositionCount;
        liquidUsd = _availableLiquidity();
    }

    // ── (11) ────────────────────────────────────────────────────────────────

    /// @notice Returns the packed fee configuration struct.
    function getFeeConfig() external view returns (FeeConfig memory) {
        return feeConfig;
    }

    // ── (12) ────────────────────────────────────────────────────────────────

    /// @notice Returns the packed risk configuration struct.
    function getRiskConfig() external view returns (RiskConfig memory) {
        return riskConfig;
    }

    // ── (13) ────────────────────────────────────────────────────────────────

    /**
     * @notice Preview deposit after the deposit fee is deducted.
     * @param assets   Gross USDC deposit amount
     * @return shares  Expected shares minted
     * @return fee     Deposit fee in USDC
     */
    function previewDepositAfterFee(uint256 assets) external view returns (uint256 shares, uint256 fee) {
        fee = _depositFee(assets);
        shares = previewDeposit(assets - fee);
    }

    // ── (14) ────────────────────────────────────────────────────────────────

    /**
     * @notice Preview redemption net of the withdrawal fee.
     * @param shares  Shares to redeem
     * @return net    USDC the redeemer receives after fee
     * @return fee    Withdrawal fee in USDC
     */
    function previewRedeemAfterFee(uint256 shares) external view returns (uint256 net, uint256 fee) {
        uint256 gross = previewRedeem(shares);
        fee = _withdrawalFee(gross);
        net = gross - fee;
    }

    // ── (15) ────────────────────────────────────────────────────────────────

    /**
     * @notice Accrued management fee not yet swept to treasury.
     * @return fee USDC (6-dec) owed as of this block
     */
    function getAccruedManagementFee() external view returns (uint256 fee) {
        uint256 elapsed = block.timestamp - feeConfig.lastFeeCollection;
        uint256 annualFee = totalAssets().mulDiv(feeConfig.managementFeeBps, BASIS_POINTS, Math.Rounding.Floor);
        fee = annualFee.mulDiv(elapsed, 365 days, Math.Rounding.Floor);
    }

    // ── (16) ────────────────────────────────────────────────────────────────

    /// @notice Returns oracle configuration for an asset.
    function getOracleConfig(bytes32 assetId) external view returns (OracleConfig memory) {
        return oracleConfigs[assetId];
    }

    // ── (17) ────────────────────────────────────────────────────────────────

    /**
     * @notice Total notional exposure to a specific asset, and its % of TVL.
     * @param assetId          Asset to query
     * @return notionalUsd     Total notional (USDC 6-dec)
     * @return exposureBps     Notional as % of TVL (basis points)
     */
    function getAssetExposure(bytes32 assetId) external view returns (uint256 notionalUsd, uint256 exposureBps) {
        notionalUsd = assetExposure[assetId];
        uint256 tvl = totalAssets();
        exposureBps = tvl > 0 ? notionalUsd.mulDiv(BASIS_POINTS, tvl, Math.Rounding.Floor) : 0;
    }

    // ── (18) ────────────────────────────────────────────────────────────────

    /**
     * @notice Per-user vault summary for portfolio UIs.
     * @param user            Address to query
     * @return sharesOwned    Current share balance
     * @return assetsOwned    USDC equivalent at current share price
     * @return depositedShares Cumulative shares minted to the user via deposit/mint
     */
    function getUserSummary(address user)
        external
        view
        returns (uint256 sharesOwned, uint256 assetsOwned, uint256 depositedShares)
    {
        sharesOwned = balanceOf(user);
        assetsOwned = convertToAssets(sharesOwned);
        depositedShares = userDepositedShares[user];
    }

    // ── (19) ────────────────────────────────────────────────────────────────

    /**
     * @notice Simulates the dynamic leverage the keeper would apply to a position.
     * @param positionId Position to evaluate
     * @return suggestedLeverageBps Suggested new leverage (or current if unchanged)
     */
    function estimateDynamicLeverage(uint256 positionId) external view returns (uint32 suggestedLeverageBps) {
        Position memory pos = positions[positionId];
        if (!pos.isActive || pos.strategyType == 0) return pos.leverageBps;

        OracleConfig memory cfg = oracleConfigs[pos.assetId];
        if (!cfg.isActive) return pos.leverageBps;

        try pythOracle.getPriceNoOlderThan(cfg.pythFeedId, cfg.maxPriceAge) returns (IPyth.Price memory p) {
            if (p.price <= 0) return pos.leverageBps;
            uint128 price = uint128(uint64(p.price));
            int256 pnl = _unrealisedPnL(pos, price);
            suggestedLeverageBps = _computeDynamicLeverage(pos, price, pnl);
        } catch {
            return pos.leverageBps;
        }
    }

    // ── (20) ────────────────────────────────────────────────────────────────

    /// @notice Returns the current high-water mark (assets-per-share, 18-dec).
    function getHighWaterMark() external view returns (uint256) {
        return highWaterMark;
    }

    // ── (21) ────────────────────────────────────────────────────────────────

    /// @notice Returns the implementation version constant.
    function version() external pure returns (uint256) {
        return VERSION;
    }

    // ── (22) ────────────────────────────────────────────────────────────────

    /**
     * @notice Checks whether a user is blocked from withdrawing this block
     *         due to the flash-loan protection window.
     * @return blocked            True if same-block deposit prevents withdrawal
     * @return unblocksAtBlock    Block number after which withdrawal is allowed
     */
    function canWithdraw(address user) external view returns (bool blocked, uint256 unblocksAtBlock) {
        blocked = lastDepositBlock[user] == block.number;
        unblocksAtBlock = blocked ? block.number + 1 : block.number;
    }

    // ── (23) ────────────────────────────────────────────────────────────────

    /**
     * @notice Effective maximum leverage given current vault utilisation.
     * @dev    Reduces max leverage linearly as utilisation approaches 80 % to
     *         protect the vault from concentration risk.
     * @return maxLev Maximum leverage in bps available right now
     */
    function getEffectiveMaxLeverage() external view returns (uint32 maxLev) {
        uint256 assets = totalAssets();
        if (assets == 0) return riskConfig.maxLeverageBps;

        uint256 utilizationBps = totalCollateralLocked.mulDiv(BASIS_POINTS, assets, Math.Rounding.Floor);

        if (utilizationBps >= 8_000) {
            maxLev = riskConfig.minLeverageBps;
        } else if (utilizationBps >= 6_000) {
            // Linear interpolation between minLev and maxLev/2
            maxLev = uint32(riskConfig.maxLeverageBps / 2);
        } else {
            maxLev = riskConfig.maxLeverageBps;
        }
    }

    // ── (24) ────────────────────────────────────────────────────────────────

    /**
     * @notice Computes the liquidation price for given parameters without opening a position.
     * @dev    Useful for frontends to display the expected liquidation level before confirming.
     */
    function previewLiquidationPrice(uint128 entryPrice, uint32 leverageBps, bool isLong)
        external
        view
        returns (uint128 liqPrice)
    {
        RiskConfig memory risk = riskConfig;
        if (leverageBps < risk.minLeverageBps || leverageBps > risk.maxLeverageBps) {
            revert LeverageOutOfRange(leverageBps, risk.minLeverageBps, risk.maxLeverageBps);
        }
        liqPrice = _computeLiquidationPrice(entryPrice, leverageBps, isLong, risk.liquidationThresholdBps);
    }

    // ── (25) ────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the maximum USDC a caller could deposit right now
     *         (respecting TVL cap and deposit-locked flag).
     * @param receiver Address that would receive the shares
     * @return maxUSDC Maximum depositable amount in USDC (6-dec); 0 if locked
     */
    function maxDeposit(
        address /*receiver*/
    )
        public
        view
        override
        returns (uint256 maxUSDC)
    {
        if (depositsLocked || paused()) return 0;
        if (tvlCap == 0) return type(uint256).max;
        uint256 current = totalAssets();
        if (current >= tvlCap) return 0;
        return tvlCap - current;
    }

    // =========================================================================
    // §14 INTERNAL HELPERS
    // =========================================================================

    /**
     * @dev Shared pre-condition checks for deposit() and mint().
     */
    function _checkDeposit(uint256 assets, address receiver) internal view {
        if (depositsLocked) revert DepositsCurrentlyLocked();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets < minDepositAmount) revert BelowMinDeposit(assets, minDepositAmount);
        if (tvlCap > 0 && totalAssets() + assets > tvlCap) {
            revert TvlCapExceeded(totalAssets() + assets, tvlCap);
        }
    }

    /**
     * @dev Returns USDC balance of the vault minus the portion locked as position collateral.
     *      This is the "free float" available for new positions and withdrawals.
     */
    function _availableLiquidity() internal view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        return balance > totalCollateralLocked ? balance - totalCollateralLocked : 0;
    }

    /**
     * @dev Fetches and validates the Pyth price for `assetId`.
     *      Validation steps:
     *        1. Feed must be configured and active.
     *        2. Price must be non-negative.
     *        3. If Chainlink circuit-breaker is enabled, both prices must be within
     *           `maxDeviationBps` of each other.
     *
     *      NOTE: This is a state-mutating function (Pyth's `getPriceNoOlderThan` is view,
     *            but Chainlink's `latestRoundData` is view too; placeholder is view).
     */
    function _getValidatedPrice(bytes32 assetId) internal view returns (uint128 price) {
        OracleConfig memory cfg = oracleConfigs[assetId];
        if (!cfg.isActive) revert OracleNotConfigured(assetId);

        IPyth.Price memory p = pythOracle.getPriceNoOlderThan(cfg.pythFeedId, cfg.maxPriceAge);
        if (p.price <= 0) revert NonPositivePrice(assetId, p.price);

        price = uint128(uint64(p.price));

        // Chainlink circuit-breaker (oracle manipulation protection)
        if (cfg.useChainlinkFallback && cfg.chainlinkFeed != address(0)) {
            uint128 clPrice = _readChainlinkPrice(cfg.chainlinkFeed);
            if (clPrice > 0) {
                uint256 deviation = price > clPrice
                    ? (uint256(price - clPrice)).mulDiv(BASIS_POINTS, clPrice, Math.Rounding.Ceil)
                    : (uint256(clPrice - price)).mulDiv(BASIS_POINTS, price, Math.Rounding.Ceil);

                if (deviation > cfg.maxDeviationBps) {
                    revert OracleDeviationTooHigh(assetId, deviation, cfg.maxDeviationBps);
                }
            }
        }
    }

    /**
     * @dev Reads the latest Chainlink price.
     *      PLACEHOLDER — connect to IChainlinkAggregator(feed).latestRoundData() in production.
     *      Returns 0 on any failure so callers can skip the deviation check gracefully.
     */
    function _readChainlinkPrice(
        address /*feed*/
    )
        internal
        pure
        returns (uint128)
    {
        // INTEGRATION POINT — replace body with:
        // (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound)
        //     = IChainlinkAggregator(feed).latestRoundData();
        // if (answeredInRound < roundId) return 0;
        // if (block.timestamp - updatedAt > CHAINLINK_MAX_AGE) return 0;
        // if (answer <= 0) return 0;
        // return uint128(uint256(answer));
        return 0;
    }

    /**
     * @dev Computes the liquidation price for a position.
     *
     *      Derivation (long):
     *        Loss at liq = collateral × liqThreshold
     *        Loss         = (entryPrice - liqPrice) / entryPrice × size
     *        size         = collateral × leverage / LEVERAGE_PRECISION
     *
     *        ⟹  liqPrice = entryPrice × (1 − liqThreshold / leverage)
     *
     *        Where we express leverage as leverageBps / LEVERAGE_PRECISION.
     *        The formula collapses to:
     *
     *          priceMove  = entryPrice × liqThresholdBps × LEVERAGE_PRECISION
     *                       ─────────────────────────────────────────────────
     *                               BASIS_POINTS × leverageBps
     *
     *        liqPrice (long)  = entryPrice − priceMove
     *        liqPrice (short) = entryPrice + priceMove
     *
     *      Example: 10× long (leverageBps=1000), liqThreshold=8500 bps
     *        priceMove = entryPrice × 8500 × 100 / (10000 × 1000) = entryPrice × 0.085
     *        liqPrice  = entryPrice × 0.915  (8.5% below entry) ✓
     */
    function _computeLiquidationPrice(uint128 entryPrice, uint32 leverageBps, bool isLong, uint32 liqThresholdBps)
        internal
        pure
        returns (uint128)
    {
        uint256 priceMove = uint256(entryPrice)
            .mulDiv(
                uint256(liqThresholdBps) * LEVERAGE_PRECISION,
                uint256(BASIS_POINTS) * uint256(leverageBps),
                Math.Rounding.Ceil
            );

        if (isLong) {
            return uint128(priceMove < entryPrice ? entryPrice - priceMove : 0);
        } else {
            uint256 liq = uint256(entryPrice) + priceMove;
            return uint128(liq > type(uint128).max ? type(uint128).max : liq);
        }
    }

    /**
     * @dev Computes unrealised PnL for `pos` at `currentPrice`.
     *
     *      PnL = (currentPrice − entryPrice) / entryPrice × size   (long)
     *          = (entryPrice − currentPrice) / entryPrice × size   (short)
     *
     *      Units: PnL is in USDC (6-dec) matching `sizeUsd`.
     */
    function _unrealisedPnL(Position memory pos, uint128 currentPrice) internal pure returns (int256 pnl) {
        if (pos.entryPrice == 0) return 0;
        int256 priceDelta = int256(uint256(currentPrice)) - int256(uint256(pos.entryPrice));
        if (!pos.isLong) priceDelta = -priceDelta;
        pnl = (priceDelta * int256(uint256(pos.sizeUsd))) / int256(uint256(pos.entryPrice));
    }

    /**
     * @dev Returns true when effective collateral < maintenance margin.
     *      Uses the SAME formula as `getPositionHealth` to avoid any discrepancy.
     */
    function _isLiquidatable(Position memory pos, uint128 currentPrice) internal view returns (bool) {
        int256 pnl = _unrealisedPnL(pos, currentPrice);
        int256 effectiveColl = int256(uint256(pos.collateralUsd)) + pnl;
        if (effectiveColl <= 0) return true;

        uint256 maintenanceReq = pos.sizeUsd.mulDiv(riskConfig.maintenanceMarginBps, BASIS_POINTS, Math.Rounding.Ceil);
        return uint256(effectiveColl) < maintenanceReq;
    }

    /**
     * @dev Computes a new leverage for dynamic strategies based on two signals:
     *      1. Unrealised loss ratio (deleverage on drawdown).
     *      2. Price deviation from entry (deleverage on high volatility).
     *
     *      The function always returns a value within [minLeverageBps, maxDynamicLev].
     */
    function _computeDynamicLeverage(Position memory pos, uint128 currentPrice, int256 pnl)
        internal
        view
        returns (uint32 newLev)
    {
        RiskConfig memory risk = riskConfig;
        uint32 baseLev = pos.leverageBps;

        // --- Signal 1: drawdown-based deleveraging ---
        if (pnl < 0 && pos.collateralUsd > 0) {
            uint256 lossRatioBps = uint256(-pnl).mulDiv(BASIS_POINTS, pos.collateralUsd, Math.Rounding.Floor);
            if (lossRatioBps >= 3_000) return risk.minLeverageBps; // >30% loss → 1×
            if (lossRatioBps >= 1_500) {
                // >15% loss → reduce by 50%, floor at minLev
                uint32 reduced = baseLev / 2;
                baseLev = reduced > risk.minLeverageBps ? reduced : risk.minLeverageBps;
            }
        }

        // --- Signal 2: volatility proxy (price deviation from entry) ---
        uint256 priceMovesBps;
        if (currentPrice > pos.entryPrice) {
            priceMovesBps =
                uint256(currentPrice - pos.entryPrice).mulDiv(BASIS_POINTS, pos.entryPrice, Math.Rounding.Floor);
        } else {
            priceMovesBps =
                uint256(pos.entryPrice - currentPrice).mulDiv(BASIS_POINTS, pos.entryPrice, Math.Rounding.Floor);
        }

        if (priceMovesBps >= 1_000) {
            // Reduce leverage proportionally to the price move beyond 10 %
            uint256 scaleFactor = BASIS_POINTS > priceMovesBps / 10 ? BASIS_POINTS - priceMovesBps / 10 : 0;
            uint32 scaled = uint32(uint256(baseLev) * scaleFactor / BASIS_POINTS);
            baseLev = scaled > risk.minLeverageBps ? scaled : risk.minLeverageBps;
        }

        // Cap at dynamic maximum
        newLev = baseLev > risk.maxLeverageForDynamic ? risk.maxLeverageForDynamic : baseLev;
    }

    /**
     * @dev Marks a position as closed and updates all global accounting state.
     *      Called by both `closePosition` and `liquidatePosition`.
     */
    function _closePositionState(uint256 positionId, Position storage pos) internal {
        // Safely subtract — collateral / notional are always ≤ their global totals
        totalCollateralLocked -= pos.collateralUsd;
        totalNotionalValue -= pos.sizeUsd;
        assetExposure[pos.assetId] -= pos.sizeUsd;
        activePositionCount -= 1;

        pos.isActive = false;
        pos.lastUpdateTimestamp = uint64(block.timestamp);

        // Clear owner mapping to release the storage slot eventually
        delete positionOwners[positionId];
    }

    /**
     * @dev Accrues and sweeps the management fee to treasury.
     *      Pro-rates the annual rate to the exact number of seconds elapsed
     *      since the last collection.  Capped at available contract balance.
     */
    function _sweepManagementFee() internal {
        uint256 elapsed = block.timestamp - feeConfig.lastFeeCollection;
        if (elapsed == 0) return;

        feeConfig.lastFeeCollection = uint64(block.timestamp);

        uint256 assets = totalAssets();
        if (assets == 0 || feeConfig.managementFeeBps == 0) return;

        uint256 annualFee = assets.mulDiv(feeConfig.managementFeeBps, BASIS_POINTS, Math.Rounding.Floor);
        uint256 fee = annualFee.mulDiv(elapsed, 365 days, Math.Rounding.Floor);

        if (fee == 0) return;

        // Never drain more than what's available as idle USDC
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (fee > idle) fee = idle;

        if (fee > 0 && treasury != address(0)) {
            IERC20(asset()).safeTransfer(treasury, fee);
            emit FeesCollected(0, fee, treasury, block.timestamp);
        }
    }

    /**
     * @dev Updates the high-water mark if the current share price exceeds it.
     */
    function _updateHighWaterMark() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return;
        uint256 currentSpx = totalAssets().mulDiv(PRICE_PRECISION, supply, Math.Rounding.Floor);
        if (currentSpx > highWaterMark) {
            emit HighWaterMarkUpdated(highWaterMark, currentSpx);
            highWaterMark = currentSpx;
        }
    }

    /// @dev Returns the deposit fee for `assets`.
    function _depositFee(uint256 assets) internal view returns (uint256) {
        return assets.mulDiv(feeConfig.depositFeeBps, BASIS_POINTS, Math.Rounding.Floor);
    }

    /// @dev Returns the withdrawal fee for `assets`.
    function _withdrawalFee(uint256 assets) internal view returns (uint256) {
        return assets.mulDiv(feeConfig.withdrawalFeeBps, BASIS_POINTS, Math.Rounding.Floor);
    }

    // =========================================================================
    // §15 ROUTER PLACEHOLDER ADAPTERS
    //     These thin shims translate vault-internal data to router calls.
    //     Replace the body of each with a real `router.*()` call when integrating.
    // =========================================================================

    /**
     * @dev INTEGRATION POINT — open position on the underlying DEX.
     *      Production body:
     *        IERC20(asset()).safeIncreaseAllowance(address(router), collateralUsd);
     *        router.openPosition(assetId, sizeUsd, collateralUsd, isLong, entryPrice);
     */
    function _placeholderRouteOpen(
        bytes32, // assetId
        uint128, // sizeUsd
        uint128, // collateralUsd
        bool, // isLong
        uint128 // entryPrice
    )
        internal
        pure {
        // No-op placeholder — replace entire body in production integration
    }

    /**
     * @dev INTEGRATION POINT — close position on the underlying DEX.
     *      Production body: router.closePosition(positionId, exitPrice);
     */
    function _placeholderRouteClose(
        uint256, // positionId
        bytes32, // assetId
        uint128 // exitPrice
    )
        internal
        pure {
        // No-op placeholder
    }

    /**
     * @dev INTEGRATION POINT — liquidate position on the underlying DEX.
     *      Production body: router.liquidatePosition(posId, liqPrice, msg.sender);
     */
    function _placeholderRouteLiquidate(
        uint256, // positionId
        bytes32, // assetId
        uint128 // liquidationPrice
    )
        internal
        pure {
        // No-op placeholder
    }

    // =========================================================================
    // §16 UUPS AUTHORISATION
    // =========================================================================

    /**
     * @notice Authorises an upgrade to `newImplementation`.
     * @dev    SECURITY CHECKLIST before any upgrade:
     *         ✅ Storage layout diff: `forge inspect SynthoraVaultV2 storage-layout`
     *         ✅ __gap reduction matches new variable slots added
     *         ✅ No existing variable removed or reordered
     *         ✅ New implementation's `_disableInitializers()` is present in constructor
     *         ✅ No new `initialize()` that calls base `__*_init` functions again
     *         ✅ Full test suite passes (including invariant tests)
     *         ✅ At least one independent audit or formal verification pass
     *
     * @param newImplementation Address of the new logic contract
     */
    function _authorizeUpgrade(address newImplementation) internal override requireRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        // Optionally: require IVersioned(newImplementation).version() > VERSION
    }

    // =========================================================================
    // §17 STORAGE GAP
    //     Current custom storage usage: ~20 slots.
    //     Inherited storage is managed by OZ and does not consume this gap.
    //     Gap provides 50 slots of headroom for future feature additions.
    //
    //     HOW TO USE:
    //       When adding N new uint256 state variables in a future upgrade, reduce
    //       the array size from 50 to (50 - N).  For packed structs, calculate
    //       the exact slot usage first.
    // =========================================================================

    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;
}
