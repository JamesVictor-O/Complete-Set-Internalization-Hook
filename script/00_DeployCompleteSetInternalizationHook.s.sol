// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

import {CompleteSetInternalizationHook} from "../src/CompleteSetInternalizationHook.sol";
import {CompleteSetQuoter} from "../src/lens/CompleteSetQuoter.sol";
import {CompleteSetLib} from "../src/libraries/CompleteSetLib.sol";
import {MockConditionalTokens} from "../test/mocks/MockConditionalTokens.sol";
import {MockWrapped1155Factory} from "../test/mocks/MockWrapped1155Factory.sol";

/// @notice Deploys {CompleteSetInternalizationHook} and {CompleteSetQuoter} end to end for the demo
/// frontend on Unichain Sepolia or an Anvil node preloaded with canonical v4 dependencies: mines the hook's CREATE2 address, deploys it against a fresh demo CTF condition,
/// registers a binary market with separate YES/dUSD and NO/dUSD pools and real core AMM liquidity (so the AMM
/// path and the executable complete-set path genuinely differ - a pool started with no liquidity, like
/// the test suite's default fixture, has nothing to contrast), seeds the hook's LP collateral reserve,
/// pre-funds the selected trader with both wrapped legs, and writes every address the
/// frontend needs to `frontend/public/deployment.json`.
/// @dev Uses the same 0.8.26-native mock CTF/Wrapped1155Factory the test suite uses (see their NatSpec
/// for why the real Gnosis contracts, being pragma ^0.5.1/^0.6.0, can't be deployed from this script
/// directly). On Unichain Sepolia these demo contracts are deliberately deployed alongside the hook;
/// compatibility with Gnosis's production contracts is covered separately by the live fork tests.
contract DeployCompleteSetInternalizationHookScript is BaseScript, LiquidityHelpers {
    using PoolIdLibrary for PoolKey;
    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////
    address constant ORACLE = address(0xFEED);
    bytes32 constant QUESTION_ID = keccak256("Will ETH be above $5,000 on Sept 30?");
    uint24 constant LP_FEE = 3000; // 0.30%
    int24 constant TICK_SPACING = 60;
    uint256 constant LP_RESERVE = 1_000 ether;
    // Thin on purpose: a modest demo trade should visibly move the AMM curve, so the CTF backstop has
    // something real to win against instead of the comparison being trivial.
    uint256 constant CORE_LIQUIDITY = 20 ether;
    uint256 constant DEMO_TRADER_FUNDING = 100 ether; // of each of wrapped YES and NO
    // Anvil's default account #1 (well-known private key) - the frontend's local demo connector signs
    // as this exact address, so it needs to already hold tokens before anyone opens the page.
    address constant DEMO_TRADER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant ANVIL_CHAIN_ID = 31337;
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    /////////////////////////////////////

    /// @dev Bundles every piece of state the deploy steps below need to share, purely to stay under
    /// Solidity's legacy-codegen stack-depth limit (each step would otherwise juggle a dozen-plus locals
    /// in one function) — see {CompleteSetLib-sellIdleLegOnCurve} for the same pattern in the hook itself.
    struct DemoMarket {
        CompleteSetInternalizationHook hook;
        CompleteSetQuoter quoter;
        MockConditionalTokens conditionalTokens;
        MockWrapped1155Factory wrapped1155Factory;
        MockERC20 collateral;
        bytes32 conditionId;
        bytes32 marketId;
        uint256 yesPositionId;
        uint256 noPositionId;
        address yesToken;
        address noToken;
        PoolKey yesPoolKey;
        PoolKey noPoolKey;
    }

    function run() external {
        require(
            block.chainid == ANVIL_CHAIN_ID || block.chainid == UNICHAIN_SEPOLIA_CHAIN_ID,
            "DeployCompleteSetInternalizationHookScript: unsupported chain"
        );
        vm.startBroadcast();
        DemoMarket memory dm = _deployHookAndMarket();
        _seedReserves(dm);
        _seedCoreLiquidity(dm, true);
        _seedCoreLiquidity(dm, false);
        _fundTrader(dm);
        vm.stopBroadcast();

        bool wroteDeploymentJson = vm.envOr("WRITE_DEPLOYMENT_JSON", true);
        if (wroteDeploymentJson) _writeDeploymentJson(dm);
        _logSummary(dm, wroteDeploymentJson);
    }

    function _deployHookAndMarket() private returns (DemoMarket memory dm) {
        dm.conditionalTokens = new MockConditionalTokens();
        dm.wrapped1155Factory = new MockWrapped1155Factory();
        dm.collateral = new MockERC20("Demo Collateral", "dUSD", 18);

        // Mine + deploy the hook at an address encoding the correct permission flags.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, dm.conditionalTokens, dm.wrapped1155Factory);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(CompleteSetInternalizationHook).creationCode, constructorArgs);
        dm.hook =
            new CompleteSetInternalizationHook{salt: salt}(poolManager, dm.conditionalTokens, dm.wrapped1155Factory);
        require(address(dm.hook) == hookAddress, "DeployCompleteSetInternalizationHookScript: Hook Address Mismatch");

        dm.quoter = new CompleteSetQuoter(poolManager, dm.hook);

        // Prepare a demo binary CTF condition and derive its wrapped YES/NO ERC-20s.
        dm.conditionalTokens.prepareCondition(ORACLE, QUESTION_ID, 2);
        dm.conditionId = CompleteSetLib.getConditionId(ORACLE, QUESTION_ID, 2);
        IERC20 collateralAsIERC20 = IERC20(address(dm.collateral));
        dm.yesPositionId = CompleteSetLib.yesPositionId(collateralAsIERC20, dm.conditionId);
        dm.noPositionId = CompleteSetLib.noPositionId(collateralAsIERC20, dm.conditionId);
        dm.yesToken = dm.wrapped1155Factory.requireWrapped1155(dm.conditionalTokens, dm.yesPositionId);
        dm.noToken = dm.wrapped1155Factory.requireWrapped1155(dm.conditionalTokens, dm.noPositionId);

        dm.yesPoolKey = _outcomePoolKey(dm, dm.yesToken);
        dm.noPoolKey = _outcomePoolKey(dm, dm.noToken);
        dm.marketId = dm.hook
            .registerMarket(dm.yesPoolKey, dm.noPoolKey, collateralAsIERC20, dm.conditionId, "YES", "YES", "NO", "NO");

        // Approximate demo probabilities: YES 60c and NO 40c. Pool price is currency1/currency0.
        poolManager.initialize(dm.yesPoolKey, _outcomeStartPrice(dm, dm.yesPoolKey, 6000));
        poolManager.initialize(dm.noPoolKey, _outcomeStartPrice(dm, dm.noPoolKey, 4000));
    }

    function _outcomePoolKey(DemoMarket memory dm, address outcome) private pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = address(dm.collateral) < outcome
            ? (Currency.wrap(address(dm.collateral)), Currency.wrap(outcome))
            : (Currency.wrap(outcome), Currency.wrap(address(dm.collateral)));
        return PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(dm.hook)});
    }

    function _outcomeStartPrice(DemoMarket memory dm, PoolKey memory key, int24 outcomePriceBps)
        private
        pure
        returns (uint160)
    {
        // tick ~= ln(price)/ln(1.0001). If collateral is currency0 the pool ratio is outcome/collateral
        // (the reciprocal of its dUSD price); otherwise it is collateral/outcome.
        int24 tick = outcomePriceBps == 6000 ? int24(5108) : int24(9163);
        bool collateralIsCurrency0 = Currency.unwrap(key.currency0) == address(dm.collateral);
        return TickMath.getSqrtPriceAtTick(collateralIsCurrency0 ? tick : -tick);
    }

    function _seedReserves(DemoMarket memory dm) private {
        dm.collateral.mint(deployerAddress, LP_RESERVE);
        dm.collateral.approve(address(dm.hook), type(uint256).max);
        dm.hook.depositCollateral(dm.marketId, LP_RESERVE);
    }

    /// @dev Seeds real, thin core AMM liquidity (full-range) — separate from the hook's own collateral
    /// reserve — so the pool actually has a curve for {CompleteSetQuoter} to quote against and for the
    /// hook's executable best-route comparison to have something real to compare against.
    function _seedCoreLiquidity(DemoMarket memory dm, bool seedYes) private {
        uint256 wrapAmount = CORE_LIQUIDITY * 20;
        _mintWrapped(dm, seedYes, deployerAddress, wrapAmount);
        dm.collateral.mint(deployerAddress, wrapAmount);

        address outcome = seedYes ? dm.yesToken : dm.noToken;
        IERC20(outcome).approve(address(permit2), type(uint256).max);
        dm.collateral.approve(address(permit2), type(uint256).max);
        permit2.approve(outcome, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(dm.collateral), address(positionManager), type(uint160).max, type(uint48).max);

        // Uses the same script-safe pattern as script/01_CreatePoolAndAddLiquidity.s.sol
        // (`LiquidityHelpers._mintLiquidityParams` + `positionManager.modifyLiquidities` directly) -
        // the test suite's `EasyPosm.mint` helper reads `address(this)`, which forge's script simulator
        // refuses to broadcast (a script contract's own address is ephemeral and not meant to be relied
        // on), so it's test-only and not usable here.
        (bytes memory actions, bytes[] memory params) = _mintLiquidityParams(
            seedYes ? dm.yesPoolKey : dm.noPoolKey,
            TickMath.minUsableTick(TICK_SPACING),
            TickMath.maxUsableTick(TICK_SPACING),
            CORE_LIQUIDITY,
            type(uint256).max,
            type(uint256).max,
            deployerAddress,
            ""
        );
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
    }

    /// @dev Splits fresh collateral through the CTF and wraps `amount` of the requested leg to `to` -
    /// exactly how a real trader or LP would source outcome tokens before this market has liquidity of
    /// its own (mirrors `_giveTraderWrapped` in the test suite).
    function _mintWrapped(DemoMarket memory dm, bool wantYes, address to, uint256 amount) private {
        dm.collateral.mint(deployerAddress, amount);
        dm.collateral.approve(address(dm.conditionalTokens), amount);
        dm.conditionalTokens
            .splitPosition(
                IERC20(address(dm.collateral)), bytes32(0), dm.conditionId, CompleteSetLib.binaryPartition(), amount
            );
        uint256 positionId = wantYes ? dm.yesPositionId : dm.noPositionId;
        bytes memory wrapData = CompleteSetLib.encodeWrappedTokenData(deployerAddress);
        dm.conditionalTokens
            .safeTransferFrom(deployerAddress, address(dm.wrapped1155Factory), positionId, amount, wrapData);
        if (to != deployerAddress) {
            address token = wantYes ? dm.yesToken : dm.noToken;
            IERC20(token).transfer(to, amount);
        }
    }

    function _fundTrader(DemoMarket memory dm) private {
        address trader = _traderAddress();
        dm.collateral.mint(trader, DEMO_TRADER_FUNDING * 2);
        _mintWrapped(dm, true, trader, DEMO_TRADER_FUNDING);
        _mintWrapped(dm, false, trader, DEMO_TRADER_FUNDING);
    }

    function _traderAddress() private view returns (address) {
        // Only Anvil can sign transactions for its well-known demo account. On testnet, fund the
        // broadcasting wallet so the same wallet can immediately exercise the deployed UI.
        return block.chainid == ANVIL_CHAIN_ID ? DEMO_TRADER : deployerAddress;
    }

    function _writeDeploymentJson(DemoMarket memory dm) private {
        string memory yesPoolKeyJson = _poolKeyJson(dm.yesPoolKey);
        string memory noPoolKeyJson = _poolKeyJson(dm.noPoolKey);

        string memory part1 = string.concat(
            "{",
            '"chainId":',
            vm.toString(block.chainid),
            ",",
            '"hook":"',
            vm.toString(address(dm.hook)),
            '",',
            '"quoter":"',
            vm.toString(address(dm.quoter)),
            '",',
            '"poolManager":"',
            vm.toString(address(poolManager)),
            '",'
        );
        string memory part2 = string.concat(
            '"swapRouter":"',
            vm.toString(address(swapRouter)),
            '",',
            '"permit2":"',
            vm.toString(address(permit2)),
            '",',
            '"collateralToken":"',
            vm.toString(address(dm.collateral)),
            '",',
            '"yesToken":"',
            vm.toString(dm.yesToken),
            '",'
        );
        string memory part3 = string.concat(
            '"noToken":"',
            vm.toString(dm.noToken),
            '",',
            '"demoTrader":"',
            vm.toString(_traderAddress()),
            '",',
            '"marketQuestion":"Will ETH be above $5,000 on Sept 30?",',
            '"marketId":"',
            vm.toString(dm.marketId),
            '",',
            '"yesPoolKey":',
            yesPoolKeyJson,
            ",",
            '"noPoolKey":',
            noPoolKeyJson,
            "}"
        );

        vm.writeJson(string.concat(part1, part2, part3), "frontend/public/deployment.json");
    }

    function _poolKeyJson(PoolKey memory key) private pure returns (string memory) {
        return string.concat(
            "{",
            '"currency0":"',
            vm.toString(Currency.unwrap(key.currency0)),
            '",',
            '"currency1":"',
            vm.toString(Currency.unwrap(key.currency1)),
            '",',
            '"fee":',
            vm.toString(uint256(key.fee)),
            ",",
            '"tickSpacing":',
            vm.toString(int256(key.tickSpacing)),
            ",",
            '"hooks":"',
            vm.toString(address(key.hooks)),
            '"}'
        );
    }

    function _logSummary(DemoMarket memory dm, bool wroteDeploymentJson) private view {
        console2.log("CompleteSetInternalizationHook deployed at:", address(dm.hook));
        console2.log("CompleteSetQuoter deployed at:", address(dm.quoter));
        console2.log("Demo collateral (dUSD):", address(dm.collateral));
        console2.log("YES token:", dm.yesToken);
        console2.log("NO token:", dm.noToken);
        console2.log("LP reserve seeded:", LP_RESERVE);
        console2.log("Core AMM liquidity seeded:", CORE_LIQUIDITY);
        console2.log("YES/dUSD pool ID:");
        console2.logBytes32(PoolId.unwrap(dm.yesPoolKey.toId()));
        console2.log("NO/dUSD pool ID:");
        console2.logBytes32(PoolId.unwrap(dm.noPoolKey.toId()));
        console2.log("Trader funded at:", _traderAddress());
        if (wroteDeploymentJson) console2.log("Wrote frontend/public/deployment.json");
    }
}
