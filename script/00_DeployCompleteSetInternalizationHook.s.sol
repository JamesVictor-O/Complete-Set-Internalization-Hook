// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {CompleteSetInternalizationHook} from "../src/CompleteSetInternalizationHook.sol";
import {CompleteSetLib} from "../src/libraries/CompleteSetLib.sol";
import {MockConditionalTokens} from "../test/mocks/MockConditionalTokens.sol";
import {MockWrapped1155Factory} from "../test/mocks/MockWrapped1155Factory.sol";

/// @notice Deploys {CompleteSetInternalizationHook} end to end: mines its CREATE2 address, deploys it
/// against a fresh demo CTF condition, registers a YES/NO market, initializes the pool at 1:1 parity,
/// seeds an LP collateral reserve, and runs one demo swap through the CTF backstop.
/// @dev Uses the same 0.8.26-native mock CTF/Wrapped1155Factory the test suite uses (see their NatSpec
/// for why the real Gnosis contracts, being pragma ^0.5.1/^0.6.0, can't be deployed from this script
/// directly). Swap in real, already-deployed CTF/Wrapped1155Factory addresses here once a target chain
/// with a live CTF deployment is chosen.
contract DeployCompleteSetInternalizationHookScript is BaseScript {
    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////
    address constant ORACLE = address(0xFEED);
    bytes32 constant QUESTION_ID = keccak256("Will ETH be above $10,000 by 2027-01-01?");
    uint24 constant LP_FEE = 3000; // 0.30%
    int24 constant TICK_SPACING = 60;
    uint160 constant START_SQRT_PRICE = 2 ** 96; // 1:1 parity
    uint256 constant LP_RESERVE = 1_000 ether;
    uint256 constant DEMO_SWAP_AMOUNT = 10 ether;
    /////////////////////////////////////

    /// @dev Bundles every piece of state the deploy steps below need to share, purely to stay under
    /// Solidity's legacy-codegen stack-depth limit (each step would otherwise juggle a dozen-plus locals
    /// in one function) — see {CompleteSetLib-sellIdleLegOnCurve} for the same pattern in the hook itself.
    struct DemoMarket {
        CompleteSetInternalizationHook hook;
        MockConditionalTokens conditionalTokens;
        MockWrapped1155Factory wrapped1155Factory;
        MockERC20 collateral;
        bytes32 conditionId;
        uint256 yesPositionId;
        uint256 noPositionId;
        address yesToken;
        address noToken;
        PoolKey poolKey;
    }

    function run() external {
        vm.startBroadcast();
        DemoMarket memory dm = _deployHookAndMarket();
        _seedReserve(dm);
        uint256 yesReceived = _demoSwap(dm);
        vm.stopBroadcast();

        console2.log("CompleteSetInternalizationHook deployed at:", address(dm.hook));
        console2.log("Demo collateral (dUSD):", address(dm.collateral));
        console2.log("YES token:", dm.yesToken);
        console2.log("NO token:", dm.noToken);
        console2.log("LP reserve seeded:", LP_RESERVE);
        console2.log("Demo swap done - YES received:", yesReceived);
    }

    function _deployHookAndMarket() private returns (DemoMarket memory dm) {
        dm.conditionalTokens = new MockConditionalTokens();
        dm.wrapped1155Factory = new MockWrapped1155Factory();
        dm.collateral = new MockERC20("Demo Collateral", "dUSD", 18);

        // Mine + deploy the hook at an address encoding the correct permission flags.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, dm.conditionalTokens, dm.wrapped1155Factory);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, flags, type(CompleteSetInternalizationHook).creationCode, constructorArgs
        );
        dm.hook =
            new CompleteSetInternalizationHook{salt: salt}(poolManager, dm.conditionalTokens, dm.wrapped1155Factory);
        require(address(dm.hook) == hookAddress, "DeployCompleteSetInternalizationHookScript: Hook Address Mismatch");

        // Prepare a demo binary CTF condition and derive its wrapped YES/NO ERC-20s.
        dm.conditionalTokens.prepareCondition(ORACLE, QUESTION_ID, 2);
        dm.conditionId = CompleteSetLib.getConditionId(ORACLE, QUESTION_ID, 2);
        IERC20 collateralAsIERC20 = IERC20(address(dm.collateral));
        dm.yesPositionId = CompleteSetLib.yesPositionId(collateralAsIERC20, dm.conditionId);
        dm.noPositionId = CompleteSetLib.noPositionId(collateralAsIERC20, dm.conditionId);
        dm.yesToken = dm.wrapped1155Factory.requireWrapped1155(
            dm.conditionalTokens, dm.yesPositionId, CompleteSetLib.encodeWrappedTokenData("YES", "YES", 18)
        );
        dm.noToken = dm.wrapped1155Factory.requireWrapped1155(
            dm.conditionalTokens, dm.noPositionId, CompleteSetLib.encodeWrappedTokenData("NO", "NO", 18)
        );

        (Currency c0, Currency c1) = dm.yesToken < dm.noToken
            ? (Currency.wrap(dm.yesToken), Currency.wrap(dm.noToken))
            : (Currency.wrap(dm.noToken), Currency.wrap(dm.yesToken));
        dm.poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(dm.hook)});

        dm.hook.registerMarket(dm.poolKey, collateralAsIERC20, dm.conditionId, "YES", "YES", "NO", "NO");
        poolManager.initialize(dm.poolKey, START_SQRT_PRICE);
    }

    function _seedReserve(DemoMarket memory dm) private {
        dm.collateral.mint(deployerAddress, LP_RESERVE);
        dm.collateral.approve(address(dm.hook), LP_RESERVE);
        dm.hook.depositCollateral(dm.poolKey, LP_RESERVE);
    }

    /// @dev Sources NO directly from the CTF (as a real trader would before this market has any AMM
    /// liquidity), then swaps it for YES through the hook's CTF backstop — a pure 1:1 NoOp fill.
    function _demoSwap(DemoMarket memory dm) private returns (uint256 yesReceived) {
        dm.collateral.mint(deployerAddress, DEMO_SWAP_AMOUNT);
        dm.collateral.approve(address(dm.conditionalTokens), DEMO_SWAP_AMOUNT);
        dm.conditionalTokens.splitPosition(
            IERC20(address(dm.collateral)), bytes32(0), dm.conditionId, CompleteSetLib.binaryPartition(), DEMO_SWAP_AMOUNT
        );
        dm.conditionalTokens.safeTransferFrom(
            deployerAddress,
            address(dm.wrapped1155Factory),
            dm.noPositionId,
            DEMO_SWAP_AMOUNT,
            CompleteSetLib.encodeWrappedTokenData("NO", "NO", 18)
        );

        IERC20(dm.noToken).approve(address(permit2), type(uint256).max);
        IERC20(dm.noToken).approve(address(swapRouter), type(uint256).max);
        permit2.approve(dm.noToken, address(swapRouter), type(uint160).max, type(uint48).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: DEMO_SWAP_AMOUNT,
            amountOutMin: DEMO_SWAP_AMOUNT,
            zeroForOne: dm.noToken == Currency.unwrap(dm.poolKey.currency0),
            poolKey: dm.poolKey,
            hookData: bytes(""),
            receiver: deployerAddress,
            deadline: block.timestamp + 3600
        });

        yesReceived = IERC20(dm.yesToken).balanceOf(deployerAddress);
    }
}
