// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";

import {Solarray} from "@solarray/Solarray.sol";

import {MockActionGuard} from "test/mock/MockActionGuard.sol";
import {MockMaliciousExtension} from "test/mock/MockMaliciousExtension.sol";
import {MockProtocol} from "test/mock/MockProtocol.sol";
import {SolarrayLlama} from "test/utils/SolarrayLlama.sol";
import {LlamaCoreSigUtils} from "test/utils/LlamaCoreSigUtils.sol";
import {LlamaFactoryWithoutInitialization} from "test/utils/LlamaFactoryWithoutInitialization.sol";
import {Roles, LlamaTestSetup} from "test/utils/LlamaTestSetup.sol";

import {IActionGuard} from "src/interfaces/IActionGuard.sol";
import {ILlamaStrategy} from "src/interfaces/ILlamaStrategy.sol";
import {ActionState} from "src/lib/Enums.sol";
import {
  Action,
  ActionInfo,
  RelativeStrategyConfig,
  PermissionData,
  RoleHolderData,
  RolePermissionData
} from "src/lib/Structs.sol";
import {RelativeStrategy} from "src/strategies/RelativeStrategy.sol";
import {LlamaAccount} from "src/LlamaAccount.sol";
import {LlamaCore} from "src/LlamaCore.sol";
import {LlamaFactory} from "src/LlamaFactory.sol";
import {LlamaPolicy} from "src/LlamaPolicy.sol";
import {DeployUtils} from "script/DeployUtils.sol";

import {LlamaCrosschainRelayer} from "src/scripts/LlamaCrosschainRelayer.sol";
import {LlamaCrosschainExecutor} from "src/crosschain/LlamaCrosschainExecutor.sol";
import {IInterchainSecurityModule} from "src/crosschain/interfaces/IInterchainSecurityModule.sol";
import {IMailbox} from "src/crosschain/interfaces/IMailbox.sol";

contract LlamaCoreTest is LlamaTestSetup, LlamaCoreSigUtils {
  event ActionCreated(
    uint256 indexed id,
    address indexed creator,
    ILlamaStrategy indexed strategy,
    address target,
    uint256 value,
    bytes data,
    string description
  );
  event ActionCanceled(uint256 id);
  event ActionQueued(
    uint256 id, address indexed caller, ILlamaStrategy indexed strategy, address indexed creator, uint256 executionTime
  );
  event ActionExecuted(
    uint256 id, address indexed caller, ILlamaStrategy indexed strategy, address indexed creator, bytes result
  );
  event ApprovalCast(uint256 id, address indexed policyholder, uint256 quantity, string reason);
  event DisapprovalCast(uint256 id, address indexed policyholder, uint256 quantity, string reason);
  event StrategyAuthorized(ILlamaStrategy indexed strategy, address indexed strategyLogic, bytes initializationData);
  event StrategyUnauthorized(ILlamaStrategy indexed strategy);
  event AccountCreated(LlamaAccount indexed account, string name);

  // We use this to easily generate, save off, and pass around `ActionInfo` structs.
  // mapping (uint256 actionId => ActionInfo) actionInfo;

  function setUp() public virtual override {
    LlamaTestSetup.setUp();

    // Setting Mock Protocol Core's EIP-712 Domain Hash
    setDomainHash(
      LlamaCoreSigUtils.EIP712Domain({
        name: mpCore.name(),
        version: "1",
        chainId: block.chainid,
        verifyingContract: address(mpCore)
      })
    );
  }

  // =========================
  // ======== Helpers ========
  // =========================

  function _createAction() public returns (ActionInfo memory actionInfo) {
    bytes memory data = abi.encodeCall(MockProtocol.pause, (true));
    vm.prank(actionCreatorAaron);
    uint256 actionId = mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data);
    actionInfo = ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data);
    vm.warp(block.timestamp + 1);
  }

  function _approveAction(address _policyholder, ActionInfo memory actionInfo) public {
    vm.expectEmit();
    emit ApprovalCast(actionInfo.id, _policyholder, 1, "");
    vm.prank(_policyholder);
    mpCore.castApproval(actionInfo, uint8(Roles.Approver));
  }

  function _disapproveAction(address _policyholder, ActionInfo memory actionInfo) public {
    vm.expectEmit();
    emit DisapprovalCast(actionInfo.id, _policyholder, 1, "");
    vm.prank(_policyholder);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));
  }

  function _queueAction(ActionInfo memory actionInfo) public {
    uint256 executionTime = block.timestamp + toRelativeStrategy(mpStrategy1).queuingPeriod();
    vm.expectEmit();
    emit ActionQueued(actionInfo.id, address(this), mpStrategy1, actionCreatorAaron, executionTime);
    mpCore.queueAction(actionInfo);
  }

  function _executeAction(ActionInfo memory actionInfo) public {
    vm.expectEmit();
    emit ActionExecuted(actionInfo.id, address(this), actionInfo.strategy, actionInfo.creator, bytes(""));
    mpCore.executeAction(actionInfo);

    Action memory action = mpCore.getAction(actionInfo.id);
    assertEq(action.executed, true);
  }

  function _executeCompleteActionFlow() internal returns (ActionInfo memory actionInfo) {
    actionInfo = _createAction();

    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
    _queueAction(actionInfo);

    vm.warp(block.timestamp + 5 days);

    _executeAction(actionInfo);
  }

  function _deployAndAuthorizeAdditionalStrategyLogic() internal returns (address) {
    RelativeStrategy additionalStrategyLogic = new RelativeStrategy();
    vm.prank(address(rootCore));
    factory.authorizeStrategyLogic(additionalStrategyLogic);
    return address(additionalStrategyLogic);
  }

  function _createStrategy(uint256 salt, bool isFixedLengthApprovalPeriod)
    internal
    pure
    returns (RelativeStrategyConfig memory)
  {
    return RelativeStrategyConfig({
      approvalPeriod: toUint64(salt % 1000 days),
      queuingPeriod: toUint64(salt % 1001 days),
      expirationPeriod: toUint64(salt % 1002 days),
      isFixedLengthApprovalPeriod: isFixedLengthApprovalPeriod,
      minApprovalPct: toUint16(salt % 10_000),
      minDisapprovalPct: toUint16(salt % 10_100),
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });
  }
}

contract Setup is LlamaCoreTest {
  function test_setUp() public {
    assertEq(address(mpCore.factory()), address(factory));
    assertEq(mpCore.name(), "Mock Protocol Llama");
    assertEq(address(mpCore.policy()), address(mpPolicy));
    assertEq(address(mpCore.llamaAccountLogic()), address(accountLogic));

    assertTrue(mpCore.authorizedStrategies(mpStrategy1));
    assertTrue(mpCore.authorizedStrategies(mpStrategy1));

    vm.expectRevert(bytes("Initializable: contract is already initialized"));
    mpAccount1.initialize("LlamaAccount0");

    vm.expectRevert(bytes("Initializable: contract is already initialized"));
    mpAccount2.initialize("LlamaAccount1");
  }
}

contract Initialize is LlamaCoreTest {
  function deployWithoutInitialization()
    internal
    returns (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore llama, LlamaPolicy policy)
  {
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account 1", "Account 2", "Account 3");
    RoleHolderData[] memory roleHolders = defaultActionCreatorRoleHolder(actionCreatorAaron);
    modifiedFactory = new LlamaFactoryWithoutInitialization(
      coreLogic,
      relativeStrategyLogic,
      accountLogic,
      policyLogic,
      policyTokenURI,
      "Root Llama",
      strategyConfigs,
      accounts,
      rootLlamaRoleDescriptions(),
      roleHolders,
      new RolePermissionData[](0)
    );

    (llama, policy) = modifiedFactory.deployWithoutInitialization(
      "NewProject", rootLlamaRoleDescriptions(), roleHolders, new RolePermissionData[](0)
    );
  }

  function test_StrategiesAreDeployedAtExpectedAddress() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    ILlamaStrategy[] memory strategyAddresses = new ILlamaStrategy[](2);
    for (uint256 i; i < strategyConfigs.length; i++) {
      strategyAddresses[i] = lens.computeLlamaStrategyAddress(
        address(relativeStrategyLogic), strategyConfigs[i], address(uninitializedLlama)
      );
    }

    assertEq(address(strategyAddresses[0]).code.length, 0);
    assertEq(address(strategyAddresses[1]).code.length, 0);

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );

    assertGt(address(strategyAddresses[0]).code.length, 0);
    assertGt(address(strategyAddresses[1]).code.length, 0);
  }

  function test_EmitsStrategyAuthorizedEventForEachStrategy() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    ILlamaStrategy[] memory strategyAddresses = new ILlamaStrategy[](2);
    for (uint256 i; i < strategyConfigs.length; i++) {
      strategyAddresses[i] = lens.computeLlamaStrategyAddress(
        address(relativeStrategyLogic), strategyConfigs[i], address(uninitializedLlama)
      );
    }

    vm.expectEmit();
    emit StrategyAuthorized(strategyAddresses[0], address(relativeStrategyLogic), strategyConfigs[0]);
    vm.expectEmit();
    emit StrategyAuthorized(strategyAddresses[1], address(relativeStrategyLogic), strategyConfigs[1]);

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );
  }

  function test_StrategiesHaveLlamaCoreAddressInStorage() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    ILlamaStrategy[] memory strategyAddresses = new ILlamaStrategy[](2);
    for (uint256 i; i < strategyConfigs.length; i++) {
      strategyAddresses[i] = lens.computeLlamaStrategyAddress(
        address(relativeStrategyLogic), strategyConfigs[i], address(uninitializedLlama)
      );
    }

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );

    assertEq(address(strategyAddresses[0].llamaCore()), address(uninitializedLlama));
    assertEq(address(strategyAddresses[1].llamaCore()), address(uninitializedLlama));
  }

  function test_StrategiesHavePolicyAddressInStorage() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    ILlamaStrategy[] memory strategyAddresses = new ILlamaStrategy[](2);
    for (uint256 i; i < strategyConfigs.length; i++) {
      strategyAddresses[i] = lens.computeLlamaStrategyAddress(
        address(relativeStrategyLogic), strategyConfigs[i], address(uninitializedLlama)
      );
    }

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );

    assertEq(address(strategyAddresses[0].policy()), address(policy));
    assertEq(address(strategyAddresses[1].policy()), address(policy));
  }

  function test_StrategiesAreAuthorizedByLlamaCore() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    ILlamaStrategy[] memory strategyAddresses = new ILlamaStrategy[](2);
    for (uint256 i; i < strategyConfigs.length; i++) {
      strategyAddresses[i] = lens.computeLlamaStrategyAddress(
        address(relativeStrategyLogic), strategyConfigs[i], address(uninitializedLlama)
      );
    }

    assertEq(uninitializedLlama.authorizedStrategies(strategyAddresses[0]), false);
    assertEq(uninitializedLlama.authorizedStrategies(strategyAddresses[1]), false);

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );

    assertEq(uninitializedLlama.authorizedStrategies(strategyAddresses[0]), true);
    assertEq(uninitializedLlama.authorizedStrategies(strategyAddresses[1]), true);
  }

  function testFuzz_RevertIf_StrategyLogicIsNotAuthorized(address notStrategyLogic) public {
    vm.assume(notStrategyLogic != address(relativeStrategyLogic));
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");

    vm.expectRevert(LlamaCore.UnauthorizedStrategyLogic.selector);
    modifiedFactory.initialize(
      uninitializedLlama,
      policy,
      "NewProject",
      ILlamaStrategy(notStrategyLogic),
      LlamaAccount(accountLogic),
      strategyConfigs,
      accounts
    );
  }

  function test_AccountsAreDeployedAtExpectedAddress() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    LlamaAccount[] memory accountAddresses = new LlamaAccount[](2);
    for (uint256 i; i < accounts.length; i++) {
      accountAddresses[i] =
        lens.computeLlamaAccountAddress(address(accountLogic), accounts[i], address(uninitializedLlama));
    }

    assertEq(address(accountAddresses[0]).code.length, 0);
    assertEq(address(accountAddresses[1]).code.length, 0);

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );

    assertGt(address(accountAddresses[0]).code.length, 0);
    assertGt(address(accountAddresses[1]).code.length, 0);
  }

  function test_EmitsAccountCreatedEventForEachAccount() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    LlamaAccount[] memory accountAddresses = new LlamaAccount[](2);
    for (uint256 i; i < accounts.length; i++) {
      accountAddresses[i] =
        lens.computeLlamaAccountAddress(address(accountLogic), accounts[i], address(uninitializedLlama));
    }

    vm.expectEmit();
    emit AccountCreated(accountAddresses[0], accounts[0]);
    vm.expectEmit();
    emit AccountCreated(accountAddresses[1], accounts[1]);
    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );
  }

  function test_AccountsHaveLlamaCoreAddressInStorage() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    LlamaAccount[] memory accountAddresses = new LlamaAccount[](2);
    for (uint256 i; i < accounts.length; i++) {
      accountAddresses[i] =
        lens.computeLlamaAccountAddress(address(accountLogic), accounts[i], address(uninitializedLlama));
    }

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );

    assertEq(address(accountAddresses[0].llamaCore()), address(uninitializedLlama));
    assertEq(address(accountAddresses[1].llamaCore()), address(uninitializedLlama));
  }

  function test_AccountsHaveNameInStorage() public {
    (LlamaFactoryWithoutInitialization modifiedFactory, LlamaCore uninitializedLlama, LlamaPolicy policy) =
      deployWithoutInitialization();
    bytes[] memory strategyConfigs = strategyConfigsRootLlama();
    string[] memory accounts = Solarray.strings("Account1", "Account2");
    LlamaAccount[] memory accountAddresses = new LlamaAccount[](2);
    for (uint256 i; i < accounts.length; i++) {
      accountAddresses[i] =
        lens.computeLlamaAccountAddress(address(accountLogic), accounts[i], address(uninitializedLlama));
    }

    modifiedFactory.initialize(
      uninitializedLlama, policy, "NewProject", relativeStrategyLogic, accountLogic, strategyConfigs, accounts
    );

    assertEq(accountAddresses[0].name(), "Account1");
    assertEq(accountAddresses[1].name(), "Account2");
  }
}

contract CreateAction is LlamaCoreTest {
  bytes data = abi.encodeCall(MockProtocol.pause, (true));

  function test_CreatesAnAction() public {
    vm.expectEmit();
    emit ActionCreated(0, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data, "");
    vm.prank(actionCreatorAaron);
    uint256 actionId = mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data);

    ActionInfo memory actionInfo = ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data);
    Action memory action = mpCore.getAction(actionInfo.id);
    uint256 approvalPeriodEnd = toRelativeStrategy(actionInfo.strategy).approvalEndTime(actionInfo);

    assertEq(actionInfo.id, 0);
    assertEq(mpCore.actionsCount(), 1);
    assertEq(action.creationTime, block.timestamp);
    assertEq(approvalPeriodEnd, block.timestamp + 2 days);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionApprovalSupply(actionInfo.id), 3);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionDisapprovalSupply(actionInfo.id), 3);
  }

  function test_CreatesAnActionWithDescription() public {
    string memory description =
      "# Transfer USDC to service provider \n This action transfers 10,000 USDC to our trusted provider.";
    vm.expectEmit();
    emit ActionCreated(0, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data, description);
    vm.prank(actionCreatorAaron);
    uint256 actionId =
      mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data, description);

    ActionInfo memory actionInfo = ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data);
    Action memory action = mpCore.getAction(actionInfo.id);
    uint256 approvalPeriodEnd = toRelativeStrategy(actionInfo.strategy).approvalEndTime(actionInfo);

    assertEq(actionInfo.id, 0);
    assertEq(mpCore.actionsCount(), 1);
    assertEq(action.creationTime, block.timestamp);
    assertEq(approvalPeriodEnd, block.timestamp + 2 days);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionApprovalSupply(actionInfo.id), 3);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionDisapprovalSupply(actionInfo.id), 3);
  }

  function testFuzz_RevertIf_PolicyholderDoesNotHavePermission(address _target, uint256 _value) public {
    vm.assume(_target != address(mockProtocol));

    bytes memory dataTrue = abi.encodeCall(MockProtocol.pause, (true));
    vm.expectRevert(LlamaCore.PolicyholderDoesNotHavePermission.selector);
    vm.prank(actionCreatorAaron);
    mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(_target), _value, dataTrue);
  }

  function test_RevertIf_ActionGuardProhibitsAction() public {
    IActionGuard guard = IActionGuard(new MockActionGuard(false, true, true, "no action creation"));

    vm.prank(address(mpCore));
    mpCore.setGuard(address(mockProtocol), PAUSE_SELECTOR, guard);

    vm.prank(actionCreatorAaron);
    vm.expectRevert("no action creation");
    mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data);
  }

  function test_RevertIf_StrategyUnauthorized() public {
    ILlamaStrategy unauthorizedStrategy = ILlamaStrategy(makeAddr("unauthorized strategy"));
    vm.prank(actionCreatorAaron);
    vm.expectRevert(LlamaCore.InvalidStrategy.selector);
    mpCore.createAction(uint8(Roles.ActionCreator), unauthorizedStrategy, address(mockProtocol), 0, data);
  }

  function test_RevertIf_StrategyIsFromAnotherLlama() public {
    ILlamaStrategy unauthorizedStrategy = rootStrategy1;
    vm.prank(actionCreatorAaron);
    vm.expectRevert(LlamaCore.InvalidStrategy.selector);
    mpCore.createAction(uint8(Roles.ActionCreator), unauthorizedStrategy, address(mockProtocol), 0, data);
  }

  function testFuzz_RevertIf_PolicyholderNotMinted(address policyholder) public {
    if (policyholder == address(0)) policyholder = address(100); // Faster than vm.assume, since 0 comes up a lot.
    vm.assume(mpPolicy.balanceOf(policyholder) == 0);
    vm.prank(policyholder);
    vm.expectRevert(LlamaCore.PolicyholderDoesNotHavePermission.selector);
    mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data);
  }

  function test_RevertIf_NoPermissionForStrategy() public {
    vm.prank(actionCreatorAaron);
    vm.expectRevert(LlamaCore.PolicyholderDoesNotHavePermission.selector);
    mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy2, address(mockProtocol), 0, data);
  }

  function testFuzz_RevertIf_NoPermissionForTarget(address _incorrectTarget) public {
    vm.assume(_incorrectTarget != address(mockProtocol));
    vm.prank(actionCreatorAaron);
    vm.expectRevert(LlamaCore.PolicyholderDoesNotHavePermission.selector);
    mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, _incorrectTarget, 0, data);
  }

  function testFuzz_RevertIf_BadPermissionForSelector(bytes4 _badSelector) public {
    vm.assume(_badSelector != PAUSE_SELECTOR && _badSelector != FAIL_SELECTOR && _badSelector != RECEIVE_ETH_SELECTOR);
    vm.prank(actionCreatorAaron);
    vm.expectRevert(LlamaCore.PolicyholderDoesNotHavePermission.selector);
    mpCore.createAction(
      uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, abi.encodeWithSelector(_badSelector)
    );
  }

  function testFuzz_RevertIf_PermissionExpired(uint64 _expirationTimestamp) public {
    vm.assume(_expirationTimestamp > block.timestamp + 1 && _expirationTimestamp < type(uint64).max - 1);
    address actionCreatorAustin = makeAddr("actionCreatorAustin");

    vm.startPrank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.ActionCreator), actionCreatorAustin, DEFAULT_ROLE_QTY, _expirationTimestamp);
    vm.stopPrank();

    vm.prank(address(actionCreatorAustin));
    mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data);

    vm.warp(_expirationTimestamp + 1);
    mpPolicy.revokeExpiredRole(uint8(Roles.ActionCreator), actionCreatorAustin);

    vm.startPrank(address(actionCreatorAustin));
    vm.expectRevert(LlamaCore.PolicyholderDoesNotHavePermission.selector);
    mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data);
  }
}

contract CreateActionBySig is LlamaCoreTest {
  function createOffchainSignature(uint256 privateKey) internal view returns (uint8 v, bytes32 r, bytes32 s) {
    LlamaCoreSigUtils.CreateAction memory createAction = LlamaCoreSigUtils.CreateAction({
      role: uint8(Roles.ActionCreator),
      strategy: address(mpStrategy1),
      target: address(mockProtocol),
      value: 0,
      data: abi.encodeCall(MockProtocol.pause, (true)),
      policyholder: actionCreatorAaron,
      nonce: 0
    });
    bytes32 digest = getCreateActionTypedDataHash(createAction);
    (v, r, s) = vm.sign(privateKey, digest);
  }

  function createActionBySig(uint8 v, bytes32 r, bytes32 s) internal returns (uint256 actionId) {
    actionId = mpCore.createActionBySig(
      uint8(Roles.ActionCreator),
      mpStrategy1,
      address(mockProtocol),
      0,
      abi.encodeCall(MockProtocol.pause, (true)),
      actionCreatorAaron,
      v,
      r,
      s
    );
  }

  function test_CreatesActionBySig() public {
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionCreatorAaronPrivateKey);
    bytes memory data = abi.encodeCall(MockProtocol.pause, (true));

    vm.expectEmit();
    emit ActionCreated(0, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data, "");

    uint256 actionId = createActionBySig(v, r, s);
    ActionInfo memory actionInfo = ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data);
    Action memory action = mpCore.getAction(actionId);

    uint256 approvalPeriodEnd = toRelativeStrategy(actionInfo.strategy).approvalEndTime(actionInfo);

    assertEq(actionId, 0);
    assertEq(mpCore.actionsCount(), 1);
    assertEq(action.creationTime, block.timestamp);
    assertEq(approvalPeriodEnd, block.timestamp + 2 days);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionApprovalSupply(actionId), 3);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionDisapprovalSupply(actionId), 3);
  }

  function test_CreatesActionBySigWithDescription() public {
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionCreatorAaronPrivateKey);
    bytes memory data = abi.encodeCall(MockProtocol.pause, (true));

    vm.expectEmit();
    emit ActionCreated(
      0, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data, "# Action 0 \n This is my action."
    );

    uint256 actionId = mpCore.createActionBySig(
      uint8(Roles.ActionCreator),
      mpStrategy1,
      address(mockProtocol),
      0,
      abi.encodeCall(MockProtocol.pause, (true)),
      actionCreatorAaron,
      v,
      r,
      s,
      "# Action 0 \n This is my action."
    );
    ActionInfo memory actionInfo = ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data);
    Action memory action = mpCore.getAction(actionId);

    uint256 approvalPeriodEnd = toRelativeStrategy(actionInfo.strategy).approvalEndTime(actionInfo);

    assertEq(actionId, 0);
    assertEq(mpCore.actionsCount(), 1);
    assertEq(action.creationTime, block.timestamp);
    assertEq(approvalPeriodEnd, block.timestamp + 2 days);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionApprovalSupply(actionId), 3);
    assertEq(toRelativeStrategy(actionInfo.strategy).actionDisapprovalSupply(actionId), 3);
  }

  function test_CheckNonceIncrements() public {
    // We need to manually calculate the function selector because we are using function overloading with the
    // createActionBySig function
    bytes4 createActionBySigWithoutDescriptionSelector = 0xfb99e5a3;
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionCreatorAaronPrivateKey);
    assertEq(mpCore.nonces(actionCreatorAaron, createActionBySigWithoutDescriptionSelector), 0);
    createActionBySig(v, r, s);
    assertEq(mpCore.nonces(actionCreatorAaron, createActionBySigWithoutDescriptionSelector), 1);
  }

  function test_OperationCannotBeReplayed() public {
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionCreatorAaronPrivateKey);
    createActionBySig(v, r, s);
    // Invalid Signature error since the recovered signer address during the second call is not the same as policyholder
    // since nonce has increased.
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    createActionBySig(v, r, s);
  }

  function test_RevertIf_SignerIsNotPolicyHolder() public {
    (, uint256 randomSignerPrivateKey) = makeAddrAndKey("randomSigner");
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(randomSignerPrivateKey);
    // Invalid Signature error since the recovered signer address is not the same as the policyholder passed in as
    // parameter.
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    createActionBySig(v, r, s);
  }

  function test_RevertIf_SignerIsZeroAddress() public {
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionCreatorAaronPrivateKey);
    // Invalid Signature error since the recovered signer address is zero address due to invalid signature values
    // (v,r,s).
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    createActionBySig((v + 1), r, s);
  }
}

contract CancelAction is LlamaCoreTest {
  ActionInfo actionInfo;

  function setUp() public override {
    LlamaCoreTest.setUp();
    actionInfo = _createAction();
  }

  function test_CreatorCancelFlow() public {
    vm.prank(actionCreatorAaron);
    vm.expectEmit();
    emit ActionCanceled(actionInfo.id);
    mpCore.cancelAction(actionInfo);

    uint256 state = uint256(mpCore.getActionState(actionInfo));
    uint256 canceled = uint256(ActionState.Canceled);
    assertEq(state, canceled);
  }

  function testFuzz_RevertIf_NotCreator(address _randomCaller) public {
    vm.assume(_randomCaller != actionCreatorAaron);
    vm.prank(_randomCaller);
    vm.expectRevert(RelativeStrategy.OnlyActionCreator.selector);
    mpCore.cancelAction(actionInfo);
  }

  function testFuzz_RevertIf_InvalidActionId(ActionInfo calldata _actionInfo) public {
    vm.prank(actionCreatorAaron);
    vm.expectRevert(LlamaCore.InfoHashMismatch.selector);
    mpCore.cancelAction(_actionInfo);
  }

  function test_RevertIf_AlreadyCanceled() public {
    vm.startPrank(actionCreatorAaron);
    mpCore.cancelAction(actionInfo);
    vm.expectRevert(abi.encodeWithSelector(RelativeStrategy.CannotCancelInState.selector, ActionState.Canceled));
    mpCore.cancelAction(actionInfo);
  }

  function test_RevertIf_ActionExecuted() public {
    ActionInfo memory _actionInfo = _executeCompleteActionFlow();

    vm.prank(actionCreatorAaron);
    vm.expectRevert(abi.encodeWithSelector(RelativeStrategy.CannotCancelInState.selector, ActionState.Executed));
    mpCore.cancelAction(_actionInfo);
  }

  function test_RevertIf_ActionExpired() public {
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
    _queueAction(actionInfo);

    _disapproveAction(disapproverDave, actionInfo);

    vm.warp(block.timestamp + 15 days);

    vm.prank(actionCreatorAaron);
    vm.expectRevert(abi.encodeWithSelector(RelativeStrategy.CannotCancelInState.selector, ActionState.Expired));
    mpCore.cancelAction(actionInfo);
  }

  function test_RevertIf_ActionFailed() public {
    _approveAction(approverAdam, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), false);

    vm.expectRevert(abi.encodeWithSelector(RelativeStrategy.CannotCancelInState.selector, ActionState.Failed));
    mpCore.cancelAction(actionInfo);
  }

  function test_RevertIf_DisapprovalDoesNotReachQuorum() public {
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
    _queueAction(actionInfo);

    vm.expectRevert(RelativeStrategy.OnlyActionCreator.selector);
    mpCore.cancelAction(actionInfo);
  }
}

contract QueueAction is LlamaCoreTest {
  function test_RevertIf_NotApproved() public {
    ActionInfo memory actionInfo = _createAction();
    _approveAction(approverAdam, actionInfo);

    vm.warp(block.timestamp + 6 days);

    vm.expectRevert(abi.encodePacked(LlamaCore.InvalidActionState.selector, uint256(ActionState.Approved)));
    mpCore.queueAction(actionInfo);
  }

  function testFuzz_RevertIf_InvalidActionId(ActionInfo calldata actionInfo) public {
    vm.expectRevert(LlamaCore.InfoHashMismatch.selector);
    mpCore.queueAction(actionInfo);
  }
}

contract ExecuteActionCrosschain is LlamaCoreTest {
  event Dispatch(address indexed sender, uint32 indexed destination, bytes32 indexed recipient, bytes message);
  event Paused();

  address private constant HYPERLANE_MAILBOX = 0x35231d4c2D8B8ADcB5617A638A0c4548684c7C70;
  address private constant POLYGON_RELAYER = 0x6c10b77002Fd0309c196DF237F1C5F394Da64f14;
  address private constant DEFAULT_ISM = 0x61A80297e77FC5395bd6Ff60EEacf7CD4f18d4a4;

  IMailbox private constant MAILBOX = IMailbox(HYPERLANE_MAILBOX);
  uint32 private constant MAINNET_CHAIN_ID = 1;
  uint32 private constant POLYGON_CHAIN_ID = 137;

  ActionInfo actionInfo;
  uint256 actionId;
  uint256 mainnetFork;
  uint256 polygonFork;

  function setUp() public override {
    mainnetFork = vm.createFork(vm.rpcUrl("mainnet"), 17_076_708);
    polygonFork = vm.createFork(vm.rpcUrl("polygon"), 41_688_510);

    vm.selectFork(polygonFork);
    LlamaCrosschainExecutor executor = new LlamaCrosschainExecutor(MAINNET_CHAIN_ID);
    MockProtocol protocol = new MockProtocol(address(executor));

    vm.selectFork(mainnetFork);
    LlamaCrosschainRelayer relayer = new LlamaCrosschainRelayer();

    LlamaCoreTest.setUp();

    bytes32 relayCallsPermissionId =
      keccak256(abi.encode(address(relayer), LlamaCrosschainRelayer.relayCalls.selector, mpStrategy1));

    vm.prank(address(mpCore));
    mpPolicy.setRolePermission(uint8(Roles.ActionCreator), relayCallsPermissionId, true);

    vm.prank(address(mpCore));
    mpCore.authorizeScript(address(relayer), true);

    bytes memory executionData = abi.encode(address(protocol), abi.encodeCall(MockProtocol.pause, (true)));
    bytes memory data =
      abi.encodeCall(LlamaCrosschainRelayer.relayCalls, (POLYGON_CHAIN_ID, address(executor), executionData));

    vm.prank(actionCreatorAaron);
    actionId = mpCore.createAction(
      uint8(Roles.ActionCreator),
      mpStrategy1,
      address(relayer),
      1e18, // value
      data
    );
    actionInfo = ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(relayer), 1e18, data);
    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
  }

  function test_ActionExecution() public {
    mpCore.queueAction(actionInfo);
    vm.warp(block.timestamp + 6 days);

    vm.expectEmit();
    emit ActionExecuted(
      0,
      address(this),
      mpStrategy1,
      actionCreatorAaron,
      hex"fe14e239a8a01b411b54a70bace2ce233a01f43f185f0d08150d2fdb02d98379"
    );
    mpCore.executeAction{value: 1e18}(actionInfo);

    bytes memory message =
      hex"00000003d20000000100000000000000000000000028cfca5ebb2ddbbcda620f2fde169b75252d3dc8000000890000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000002e234dae75c793f67a35089c9d99245e1c58470b0000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000002402329a29000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000";

    vm.selectFork(polygonFork);
    vm.startPrank(POLYGON_RELAYER);
    vm.mockCall(
      DEFAULT_ISM, abi.encodeWithSelector(IInterchainSecurityModule.verify.selector, "", message), abi.encode(true)
    );

    vm.expectEmit();
    emit Paused();
    MAILBOX.process("", message);
  }

  fallback() external payable {}

  receive() external payable {}
}

contract ExecuteAction is LlamaCoreTest {
  ActionInfo actionInfo;

  function setUp() public override {
    LlamaCoreTest.setUp();

    actionInfo = _createAction();
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
  }

  function test_ActionExecution() public {
    mpCore.queueAction(actionInfo);
    vm.warp(block.timestamp + 6 days);

    vm.expectEmit();
    emit ActionExecuted(0, address(this), mpStrategy1, actionCreatorAaron, bytes(""));
    mpCore.executeAction(actionInfo);
  }

  function test_ScriptsAlwaysUseDelegatecall() public {
    address actionCreatorAustin = makeAddr("actionCreatorAustin");

    vm.prank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.TestRole2), actionCreatorAustin, DEFAULT_ROLE_QTY, DEFAULT_ROLE_EXPIRATION);

    vm.prank(address(mpCore));
    mpCore.authorizeScript(address(mockScript), true);

    bytes memory data = abi.encodeWithSelector(EXECUTE_SCRIPT_SELECTOR);
    vm.prank(actionCreatorAustin);
    uint256 actionId = mpCore.createAction(uint8(Roles.TestRole2), mpStrategy1, address(mockScript), 0, data);
    ActionInfo memory _actionInfo = ActionInfo(actionId, actionCreatorAustin, mpStrategy1, address(mockScript), 0, data);

    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, _actionInfo);
    _approveAction(approverAlicia, _actionInfo);

    vm.warp(block.timestamp + 6 days);

    mpCore.queueAction(_actionInfo);

    vm.warp(block.timestamp + 5 days);

    vm.expectEmit();
    // Checking that the result is a delegatecall because msg.sender is this contract and not mpCore
    emit ActionExecuted(_actionInfo.id, address(this), mpStrategy1, actionCreatorAustin, abi.encode(address(this)));
    mpCore.executeAction(_actionInfo);
  }

  function test_RevertIf_Slot0Changes() public {
    address actionCreatorAustin = makeAddr("actionCreatorAustin");
    MockMaliciousExtension mockMaliciousScript = new MockMaliciousExtension();

    bytes32 permissionId1 =
      keccak256(abi.encode(address(mockMaliciousScript), MockMaliciousExtension.attack1.selector, mpStrategy1));
    bytes32 permissionId2 =
      keccak256(abi.encode(address(mockMaliciousScript), MockMaliciousExtension.attack2.selector, mpStrategy1));

    vm.startPrank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.TestRole2), actionCreatorAustin, DEFAULT_ROLE_QTY, DEFAULT_ROLE_EXPIRATION);
    mpCore.authorizeScript(address(mockMaliciousScript), true);
    mpPolicy.setRolePermission(uint8(Roles.TestRole2), permissionId1, true);
    mpPolicy.setRolePermission(uint8(Roles.TestRole2), permissionId2, true);
    vm.stopPrank();

    bytes memory data1 = abi.encodeCall(MockMaliciousExtension.attack1, ());
    bytes memory data2 = abi.encodeCall(MockMaliciousExtension.attack2, ());

    vm.prank(actionCreatorAustin);
    uint256 actionId1 = mpCore.createAction(uint8(Roles.TestRole2), mpStrategy1, address(mockMaliciousScript), 0, data1);
    ActionInfo memory _actionInfo1 =
      ActionInfo(actionId1, actionCreatorAustin, mpStrategy1, address(mockMaliciousScript), 0, data1);

    vm.prank(actionCreatorAustin);
    uint256 actionId2 = mpCore.createAction(uint8(Roles.TestRole2), mpStrategy1, address(mockMaliciousScript), 0, data2);
    ActionInfo memory _actionInfo2 =
      ActionInfo(actionId2, actionCreatorAustin, mpStrategy1, address(mockMaliciousScript), 0, data2);
    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, _actionInfo1);
    _approveAction(approverAlicia, _actionInfo1);
    _approveAction(approverAdam, _actionInfo2);
    _approveAction(approverAlicia, _actionInfo2);

    vm.warp(block.timestamp + 6 days);

    mpCore.queueAction(_actionInfo1);
    mpCore.queueAction(_actionInfo2);

    vm.warp(block.timestamp + 5 days);

    vm.expectRevert(LlamaCore.Slot0Changed.selector);
    mpCore.executeAction(_actionInfo1);

    vm.expectRevert(LlamaCore.Slot0Changed.selector);
    mpCore.executeAction(_actionInfo2);
  }

  function test_RevertIf_NotQueued() public {
    vm.expectRevert(abi.encodePacked(LlamaCore.InvalidActionState.selector, uint256(ActionState.Queued)));
    mpCore.executeAction(actionInfo);

    // Check that it's in the Approved state
    assertEq(uint256(mpCore.getActionState(actionInfo)), uint256(3));
  }

  function test_RevertIf_ActionGuardProhibitsActionPreExecution() public {
    IActionGuard guard = IActionGuard(new MockActionGuard(true, false, true, "no action pre-execution"));

    vm.prank(address(mpCore));
    mpCore.setGuard(address(mockProtocol), PAUSE_SELECTOR, guard);

    mpCore.queueAction(actionInfo);
    vm.warp(block.timestamp + 6 days);

    vm.expectRevert("no action pre-execution");
    mpCore.executeAction(actionInfo);
  }

  function test_RevertIf_ActionGuardProhibitsActionPostExecution() public {
    IActionGuard guard = IActionGuard(new MockActionGuard(true, true, false, "no action post-execution"));

    vm.prank(address(mpCore));
    mpCore.setGuard(address(mockProtocol), PAUSE_SELECTOR, guard);

    mpCore.queueAction(actionInfo);
    vm.warp(block.timestamp + 6 days);

    vm.expectRevert("no action post-execution");
    mpCore.executeAction(actionInfo);
  }

  function testFuzz_RevertIf_InvalidAction(ActionInfo calldata _actionInfo) public {
    vm.expectRevert(LlamaCore.InfoHashMismatch.selector);
    mpCore.executeAction(_actionInfo);
  }

  function testFuzz_RevertIf_TimelockNotFinished(uint256 timeElapsed) public {
    // Using a reasonable upper limit for elapsedTime
    vm.assume(timeElapsed < 10_000 days);
    mpCore.queueAction(actionInfo);
    uint256 executionTime = mpCore.getAction(actionInfo.id).minExecutionTime;

    vm.warp(block.timestamp + timeElapsed);

    if (executionTime > block.timestamp) {
      vm.expectRevert(LlamaCore.TimelockNotFinished.selector);
      mpCore.executeAction(actionInfo);
    }
  }

  function test_RevertIf_InsufficientMsgValue() public {
    bytes memory data = abi.encodeCall(MockProtocol.receiveEth, ());
    vm.prank(actionCreatorAaron);
    uint256 actionId = mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 1e18, data);
    ActionInfo memory _actionInfo =
      ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(mockProtocol), 1e18, data);

    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, _actionInfo);
    _approveAction(approverAlicia, _actionInfo);

    vm.warp(block.timestamp + 6 days);

    mpCore.queueAction(_actionInfo);

    vm.warp(block.timestamp + 5 days);

    vm.expectRevert(LlamaCore.InsufficientMsgValue.selector);
    mpCore.executeAction(_actionInfo);
  }

  function test_RevertIf_FailedActionExecution() public {
    bytes memory data = abi.encodeCall(MockProtocol.fail, ());
    vm.prank(actionCreatorAaron);
    uint256 actionId = mpCore.createAction(uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, data);
    ActionInfo memory _actionInfo =
      ActionInfo(actionId, actionCreatorAaron, mpStrategy1, address(mockProtocol), 0, data);

    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, _actionInfo);
    _approveAction(approverAlicia, _actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(_actionInfo), true);

    mpCore.queueAction(_actionInfo);

    vm.warp(block.timestamp + 5 days);

    bytes memory expectedErr = abi.encodeWithSelector(
      LlamaCore.FailedActionExecution.selector, abi.encodeWithSelector(MockProtocol.Failed.selector)
    );
    vm.expectRevert(expectedErr);
    mpCore.executeAction(_actionInfo);
  }

  function test_HandlesReentrancy() public {
    address actionCreatorAustin = makeAddr("actionCreatorAustin");
    bytes memory expectedErr = abi.encodeWithSelector(
      LlamaCore.FailedActionExecution.selector,
      abi.encodeWithSelector(LlamaCore.InvalidActionState.selector, (ActionState.Queued))
    );

    vm.startPrank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.TestRole2), actionCreatorAustin, DEFAULT_ROLE_QTY, DEFAULT_ROLE_EXPIRATION);
    vm.stopPrank();

    bytes memory data = abi.encodeCall(LlamaCore.executeAction, (actionInfo));
    vm.prank(actionCreatorAustin);
    uint256 actionId = mpCore.createAction(uint8(Roles.TestRole2), mpStrategy1, address(mpCore), 0, data);
    ActionInfo memory _actionInfo = ActionInfo(actionId, actionCreatorAustin, mpStrategy1, address(mpCore), 0, data);

    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, _actionInfo);
    _approveAction(approverAlicia, _actionInfo);

    vm.warp(block.timestamp + 6 days);

    mpCore.queueAction(_actionInfo);

    vm.warp(block.timestamp + 5 days);

    vm.expectRevert(expectedErr);
    mpCore.executeAction(_actionInfo);
  }
}

contract CastApproval is LlamaCoreTest {
  ActionInfo actionInfo;

  function setUp() public override {
    LlamaCoreTest.setUp();
    actionInfo = _createAction();
  }

  function test_SuccessfulApproval() public {
    _approveAction(approverAdam, actionInfo);
    assertEq(mpCore.getAction(0).totalApprovals, 1);
    assertEq(mpCore.approvals(0, approverAdam), true);
  }

  function test_SuccessfulApprovalWithReason(string calldata reason) public {
    vm.expectEmit();
    emit ApprovalCast(actionInfo.id, approverAdam, 1, reason);
    vm.prank(approverAdam);
    mpCore.castApproval(actionInfo, uint8(Roles.Approver), reason);
  }

  function test_RevertIf_ActionNotActive() public {
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    mpCore.queueAction(actionInfo);

    vm.expectRevert(abi.encodePacked(LlamaCore.InvalidActionState.selector, uint256(ActionState.Active)));
    mpCore.castApproval(actionInfo, uint8(Roles.Approver));
  }

  function test_RevertIf_DuplicateApproval() public {
    _approveAction(approverAdam, actionInfo);

    vm.expectRevert(LlamaCore.DuplicateCast.selector);
    vm.prank(approverAdam);
    mpCore.castApproval(actionInfo, uint8(Roles.Approver));
  }

  function test_RevertIf_InvalidPolicyholder() public {
    address notPolicyholder = 0x9D3de545F58C696946b4Cf2c884fcF4f7914cB53;
    vm.prank(notPolicyholder);

    vm.expectRevert(LlamaCore.InvalidPolicyholder.selector);
    mpCore.castApproval(actionInfo, uint8(Roles.Approver));

    vm.prank(approverAdam);
    mpCore.castApproval(actionInfo, uint8(Roles.Approver));
  }
}

contract CastApprovalBySig is LlamaCoreTest {
  function createOffchainSignature(ActionInfo memory actionInfo, uint256 privateKey)
    internal
    view
    returns (uint8 v, bytes32 r, bytes32 s)
  {
    LlamaCoreSigUtils.CastApproval memory castApproval = LlamaCoreSigUtils.CastApproval({
      actionInfo: actionInfo,
      role: uint8(Roles.Approver),
      reason: "",
      policyholder: approverAdam,
      nonce: 0
    });
    bytes32 digest = getCastApprovalTypedDataHash(castApproval);
    (v, r, s) = vm.sign(privateKey, digest);
  }

  function castApprovalBySig(ActionInfo memory actionInfo, uint8 v, bytes32 r, bytes32 s) internal {
    mpCore.castApprovalBySig(actionInfo, uint8(Roles.Approver), "", approverAdam, v, r, s);
  }

  function test_CastsApprovalBySig() public {
    ActionInfo memory actionInfo = _createAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, approverAdamPrivateKey);

    vm.expectEmit();
    emit ApprovalCast(actionInfo.id, approverAdam, 1, "");

    castApprovalBySig(actionInfo, v, r, s);

    assertEq(mpCore.getAction(0).totalApprovals, 1);
    assertEq(mpCore.approvals(0, approverAdam), true);
  }

  function test_CheckNonceIncrements() public {
    ActionInfo memory actionInfo = _createAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, approverAdamPrivateKey);

    assertEq(mpCore.nonces(approverAdam, LlamaCore.castApprovalBySig.selector), 0);
    castApprovalBySig(actionInfo, v, r, s);
    assertEq(mpCore.nonces(approverAdam, LlamaCore.castApprovalBySig.selector), 1);
  }

  function test_OperationCannotBeReplayed() public {
    ActionInfo memory actionInfo = _createAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, approverAdamPrivateKey);
    castApprovalBySig(actionInfo, v, r, s);
    // Invalid Signature error since the recovered signer address during the second call is not the same as policyholder
    // since nonce has increased.
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    castApprovalBySig(actionInfo, v, r, s);
  }

  function test_RevertIf_SignerIsNotPolicyHolder() public {
    ActionInfo memory actionInfo = _createAction();

    (, uint256 randomSignerPrivateKey) = makeAddrAndKey("randomSigner");
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, randomSignerPrivateKey);
    // Invalid Signature error since the recovered signer address is not the same as the policyholder passed in as
    // parameter.
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    castApprovalBySig(actionInfo, v, r, s);
  }

  function test_RevertIf_SignerIsZeroAddress() public {
    ActionInfo memory actionInfo = _createAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, approverAdamPrivateKey);
    // Invalid Signature error since the recovered signer address is zero address due to invalid signature values
    // (v,r,s).
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    castApprovalBySig(actionInfo, (v + 1), r, s);
  }
}

contract CastDisapproval is LlamaCoreTest {
  function _createApproveAndQueueAction() internal returns (ActionInfo memory actionInfo) {
    actionInfo = _createAction();
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
    _queueAction(actionInfo);
  }

  function test_SuccessfulDisapproval() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    vm.prank(disapproverDrake);
    vm.expectEmit();
    emit DisapprovalCast(actionInfo.id, disapproverDrake, 1, "");

    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));

    assertEq(mpCore.getAction(0).totalDisapprovals, 1);
    assertEq(mpCore.disapprovals(0, disapproverDrake), true);
  }

  function test_SuccessfulDisapprovalWithReason(string calldata reason) public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();
    vm.expectEmit();
    emit DisapprovalCast(actionInfo.id, disapproverDrake, 1, reason);
    vm.prank(disapproverDrake);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover), reason);
  }

  function test_RevertIf_ActionNotQueued() public {
    ActionInfo memory actionInfo = _createAction();

    vm.expectRevert(abi.encodePacked(LlamaCore.InvalidActionState.selector, uint256(ActionState.Queued)));
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));
  }

  function test_RevertIf_DuplicateDisapproval() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    _disapproveAction(disapproverDrake, actionInfo);

    vm.expectRevert(LlamaCore.DuplicateCast.selector);
    vm.prank(disapproverDrake);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));
  }

  function test_RevertIf_InvalidPolicyholder() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();
    address notPolicyholder = 0x9D3de545F58C696946b4Cf2c884fcF4f7914cB53;
    vm.prank(notPolicyholder);

    vm.expectRevert(LlamaCore.InvalidPolicyholder.selector);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));

    vm.prank(disapproverDrake);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));
  }

  function test_FailsIfDisapproved() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    vm.prank(disapproverDave);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));
    vm.prank(disapproverDrake);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));

    ActionState state = mpCore.getActionState(actionInfo);
    assertEq(uint8(state), uint8(ActionState.Failed));

    vm.expectRevert(abi.encodeWithSelector(LlamaCore.InvalidActionState.selector, ActionState.Queued));
    mpCore.executeAction(actionInfo);
  }
}

contract CastDisapprovalBySig is LlamaCoreTest {
  function createOffchainSignature(ActionInfo memory actionInfo, uint256 privateKey)
    internal
    view
    returns (uint8 v, bytes32 r, bytes32 s)
  {
    LlamaCoreSigUtils.CastDisapproval memory castDisapproval = LlamaCoreSigUtils.CastDisapproval({
      actionInfo: actionInfo,
      role: uint8(Roles.Disapprover),
      reason: "",
      policyholder: disapproverDrake,
      nonce: 0
    });
    bytes32 digest = getCastDisapprovalTypedDataHash(castDisapproval);
    (v, r, s) = vm.sign(privateKey, digest);
  }

  function castDisapprovalBySig(ActionInfo memory actionInfo, uint8 v, bytes32 r, bytes32 s) internal {
    mpCore.castDisapprovalBySig(actionInfo, uint8(Roles.Disapprover), "", disapproverDrake, v, r, s);
  }

  function _createApproveAndQueueAction() internal returns (ActionInfo memory actionInfo) {
    actionInfo = _createAction();
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(actionInfo.strategy.isActionApproved(actionInfo), true);
    _queueAction(actionInfo);
  }

  function test_CastsDisapprovalBySig() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, disapproverDrakePrivateKey);

    vm.expectEmit();
    emit DisapprovalCast(actionInfo.id, disapproverDrake, 1, "");

    castDisapprovalBySig(actionInfo, v, r, s);

    assertEq(mpCore.getAction(0).totalDisapprovals, 1);
    assertEq(mpCore.disapprovals(0, disapproverDrake), true);
  }

  function test_CheckNonceIncrements() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, disapproverDrakePrivateKey);

    assertEq(mpCore.nonces(disapproverDrake, LlamaCore.castDisapprovalBySig.selector), 0);
    castDisapprovalBySig(actionInfo, v, r, s);
    assertEq(mpCore.nonces(disapproverDrake, LlamaCore.castDisapprovalBySig.selector), 1);
  }

  function test_OperationCannotBeReplayed() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, disapproverDrakePrivateKey);
    castDisapprovalBySig(actionInfo, v, r, s);
    // Invalid Signature error since the recovered signer address during the second call is not the same as policyholder
    // since nonce has increased.
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    castDisapprovalBySig(actionInfo, v, r, s);
  }

  function test_RevertIf_SignerIsNotPolicyHolder() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    (, uint256 randomSignerPrivateKey) = makeAddrAndKey("randomSigner");
    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, randomSignerPrivateKey);
    // Invalid Signature error since the recovered signer address during the second call is not the same as policyholder
    // since nonce has increased.
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    castDisapprovalBySig(actionInfo, v, r, s);
  }

  function test_RevertIf_SignerIsZeroAddress() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, disapproverDrakePrivateKey);
    // Invalid Signature error since the recovered signer address is zero address due to invalid signature values
    // (v,r,s).
    vm.expectRevert(LlamaCore.InvalidSignature.selector);
    castDisapprovalBySig(actionInfo, (v + 1), r, s);
  }

  function test_FailsIfDisapproved() public {
    ActionInfo memory actionInfo = _createApproveAndQueueAction();

    (uint8 v, bytes32 r, bytes32 s) = createOffchainSignature(actionInfo, disapproverDrakePrivateKey);

    // First disapproval.
    vm.expectEmit();
    emit DisapprovalCast(actionInfo.id, disapproverDrake, 1, "");
    castDisapprovalBySig(actionInfo, v, r, s);
    assertEq(mpCore.getAction(actionInfo.id).totalDisapprovals, 1);

    // Second disapproval.
    vm.prank(disapproverDave);
    mpCore.castDisapproval(actionInfo, uint8(Roles.Disapprover));

    // Assertions.
    ActionState state = mpCore.getActionState(actionInfo);
    assertEq(uint8(state), uint8(ActionState.Failed));

    vm.expectRevert(abi.encodeWithSelector(LlamaCore.InvalidActionState.selector, ActionState.Queued));
    mpCore.executeAction(actionInfo);
  }
}

contract CreateAndAuthorizeStrategies is LlamaCoreTest {
  function testFuzz_RevertIf_CallerIsNotLlama(address caller) public {
    vm.assume(caller != address(mpCore));
    vm.expectRevert(LlamaCore.OnlyLlama.selector);
    RelativeStrategyConfig[] memory newStrategies = new RelativeStrategyConfig[](3);

    vm.prank(caller);
    mpCore.createAndAuthorizeStrategies(relativeStrategyLogic, DeployUtils.encodeStrategyConfigs(newStrategies));
  }

  function test_CreateNewStrategies(uint256 salt1, uint256 salt2, uint256 salt3, bool isFixedLengthApprovalPeriod)
    public
  {
    RelativeStrategyConfig[] memory newStrategies = new RelativeStrategyConfig[](3);
    ILlamaStrategy[] memory strategyAddresses = new ILlamaStrategy[](3);
    vm.assume(salt1 != salt2);
    vm.assume(salt1 != salt3);
    vm.assume(salt2 != salt3);

    newStrategies[0] = _createStrategy(salt1, isFixedLengthApprovalPeriod);
    newStrategies[1] = _createStrategy(salt2, isFixedLengthApprovalPeriod);
    newStrategies[2] = _createStrategy(salt3, isFixedLengthApprovalPeriod);

    for (uint256 i; i < newStrategies.length; i++) {
      strategyAddresses[i] = lens.computeLlamaStrategyAddress(
        address(relativeStrategyLogic), DeployUtils.encodeStrategy(newStrategies[i]), address(mpCore)
      );
    }

    vm.startPrank(address(mpCore));

    vm.expectEmit();
    emit StrategyAuthorized(
      strategyAddresses[0], address(relativeStrategyLogic), DeployUtils.encodeStrategy(newStrategies[0])
    );
    vm.expectEmit();
    emit StrategyAuthorized(
      strategyAddresses[1], address(relativeStrategyLogic), DeployUtils.encodeStrategy(newStrategies[1])
    );
    vm.expectEmit();
    emit StrategyAuthorized(
      strategyAddresses[2], address(relativeStrategyLogic), DeployUtils.encodeStrategy(newStrategies[2])
    );

    mpCore.createAndAuthorizeStrategies(relativeStrategyLogic, DeployUtils.encodeStrategyConfigs(newStrategies));

    assertEq(mpCore.authorizedStrategies(strategyAddresses[0]), true);
    assertEq(mpCore.authorizedStrategies(strategyAddresses[1]), true);
    assertEq(mpCore.authorizedStrategies(strategyAddresses[2]), true);
  }

  function test_CreateNewStrategiesWithAdditionalStrategyLogic() public {
    address additionalStrategyLogic = _deployAndAuthorizeAdditionalStrategyLogic();

    RelativeStrategyConfig[] memory newStrategies = new RelativeStrategyConfig[](3);
    ILlamaStrategy[] memory strategyAddresses = new ILlamaStrategy[](3);

    newStrategies[0] = RelativeStrategyConfig({
      approvalPeriod: 4 days,
      queuingPeriod: 14 days,
      expirationPeriod: 3 days,
      isFixedLengthApprovalPeriod: false,
      minApprovalPct: 0,
      minDisapprovalPct: 2000,
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });

    newStrategies[1] = RelativeStrategyConfig({
      approvalPeriod: 5 days,
      queuingPeriod: 14 days,
      expirationPeriod: 3 days,
      isFixedLengthApprovalPeriod: false,
      minApprovalPct: 0,
      minDisapprovalPct: 2000,
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });

    newStrategies[2] = RelativeStrategyConfig({
      approvalPeriod: 6 days,
      queuingPeriod: 14 days,
      expirationPeriod: 3 days,
      isFixedLengthApprovalPeriod: false,
      minApprovalPct: 0,
      minDisapprovalPct: 2000,
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });

    for (uint256 i; i < newStrategies.length; i++) {
      strategyAddresses[i] = lens.computeLlamaStrategyAddress(
        additionalStrategyLogic, DeployUtils.encodeStrategy(newStrategies[i]), address(mpCore)
      );
    }

    vm.startPrank(address(mpCore));

    vm.expectEmit();
    emit StrategyAuthorized(strategyAddresses[0], additionalStrategyLogic, DeployUtils.encodeStrategy(newStrategies[0]));
    vm.expectEmit();
    emit StrategyAuthorized(strategyAddresses[1], additionalStrategyLogic, DeployUtils.encodeStrategy(newStrategies[1]));
    vm.expectEmit();
    emit StrategyAuthorized(strategyAddresses[2], additionalStrategyLogic, DeployUtils.encodeStrategy(newStrategies[2]));

    mpCore.createAndAuthorizeStrategies(
      ILlamaStrategy(additionalStrategyLogic), DeployUtils.encodeStrategyConfigs(newStrategies)
    );

    assertEq(mpCore.authorizedStrategies(strategyAddresses[0]), true);
    assertEq(mpCore.authorizedStrategies(strategyAddresses[1]), true);
    assertEq(mpCore.authorizedStrategies(strategyAddresses[2]), true);
  }

  function test_RevertIf_StrategyLogicNotAuthorized() public {
    RelativeStrategyConfig[] memory newStrategies = new RelativeStrategyConfig[](1);

    newStrategies[0] = RelativeStrategyConfig({
      approvalPeriod: 4 days,
      queuingPeriod: 14 days,
      expirationPeriod: 3 days,
      isFixedLengthApprovalPeriod: false,
      minApprovalPct: 0,
      minDisapprovalPct: 2000,
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });

    vm.startPrank(address(mpCore));

    vm.expectRevert(LlamaCore.UnauthorizedStrategyLogic.selector);
    mpCore.createAndAuthorizeStrategies(
      ILlamaStrategy(randomLogicAddress), DeployUtils.encodeStrategyConfigs(newStrategies)
    );
  }

  function test_RevertIf_StrategiesAreIdentical() public {
    RelativeStrategyConfig[] memory newStrategies = new RelativeStrategyConfig[](2);

    RelativeStrategyConfig memory duplicateStrategy = RelativeStrategyConfig({
      approvalPeriod: 4 days,
      queuingPeriod: 14 days,
      expirationPeriod: 3 days,
      isFixedLengthApprovalPeriod: false,
      minApprovalPct: 0,
      minDisapprovalPct: 2000,
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });

    newStrategies[0] = duplicateStrategy;
    newStrategies[1] = duplicateStrategy;

    vm.startPrank(address(mpCore));

    vm.expectRevert("ERC1167: create2 failed");
    mpCore.createAndAuthorizeStrategies(relativeStrategyLogic, DeployUtils.encodeStrategyConfigs(newStrategies));
  }

  function test_RevertIf_IdenticalStrategyIsAlreadyDeployed() public {
    RelativeStrategyConfig[] memory newStrategies1 = new RelativeStrategyConfig[](1);
    RelativeStrategyConfig[] memory newStrategies2 = new RelativeStrategyConfig[](1);

    RelativeStrategyConfig memory duplicateStrategy = RelativeStrategyConfig({
      approvalPeriod: 4 days,
      queuingPeriod: 14 days,
      expirationPeriod: 3 days,
      isFixedLengthApprovalPeriod: false,
      minApprovalPct: 0,
      minDisapprovalPct: 2000,
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });

    newStrategies1[0] = duplicateStrategy;
    newStrategies2[0] = duplicateStrategy;

    vm.startPrank(address(mpCore));
    mpCore.createAndAuthorizeStrategies(relativeStrategyLogic, DeployUtils.encodeStrategyConfigs(newStrategies1));

    vm.expectRevert("ERC1167: create2 failed");
    mpCore.createAndAuthorizeStrategies(relativeStrategyLogic, DeployUtils.encodeStrategyConfigs(newStrategies2));
  }

  function test_CanBeCalledByASuccessfulAction() public {
    address actionCreatorAustin = makeAddr("actionCreatorAustin");

    RelativeStrategyConfig[] memory newStrategies = new RelativeStrategyConfig[](1);

    newStrategies[0] = RelativeStrategyConfig({
      approvalPeriod: 4 days,
      queuingPeriod: 14 days,
      expirationPeriod: 3 days,
      isFixedLengthApprovalPeriod: false,
      minApprovalPct: 0,
      minDisapprovalPct: 2000,
      approvalRole: uint8(Roles.Approver),
      disapprovalRole: uint8(Roles.Disapprover),
      forceApprovalRoles: new uint8[](0),
      forceDisapprovalRoles: new uint8[](0)
    });

    ILlamaStrategy strategyAddress = lens.computeLlamaStrategyAddress(
      address(relativeStrategyLogic), DeployUtils.encodeStrategy(newStrategies[0]), address(mpCore)
    );

    vm.prank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.TestRole2), actionCreatorAustin, DEFAULT_ROLE_QTY, DEFAULT_ROLE_EXPIRATION);

    bytes memory data = abi.encodeCall(
      LlamaCore.createAndAuthorizeStrategies, (relativeStrategyLogic, DeployUtils.encodeStrategyConfigs(newStrategies))
    );
    vm.prank(actionCreatorAustin);
    uint256 actionId = mpCore.createAction(uint8(Roles.TestRole2), mpStrategy1, address(mpCore), 0, data);
    ActionInfo memory actionInfo = ActionInfo(actionId, actionCreatorAustin, mpStrategy1, address(mpCore), 0, data);

    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    mpCore.queueAction(actionInfo);

    vm.warp(block.timestamp + 5 days);

    mpCore.executeAction(actionInfo);

    assertEq(mpCore.authorizedStrategies(strategyAddress), true);
  }
}

contract UnauthorizeStrategies is LlamaCoreTest {
  function testFuzz_RevertIf_CallerIsNotLlama(address caller) public {
    vm.assume(caller != address(mpCore));
    vm.expectRevert(LlamaCore.OnlyLlama.selector);
    ILlamaStrategy[] memory strategies = new ILlamaStrategy[](0);

    vm.prank(caller);
    mpCore.unauthorizeStrategies(strategies);
  }

  function test_UnauthorizeStrategies() public {
    vm.startPrank(address(mpCore));
    assertEq(mpCore.authorizedStrategies(mpStrategy1), true);
    assertEq(mpCore.authorizedStrategies(mpStrategy2), true);

    vm.expectEmit();
    emit StrategyUnauthorized(mpStrategy1);
    vm.expectEmit();
    emit StrategyUnauthorized(mpStrategy2);

    ILlamaStrategy[] memory strategies = new ILlamaStrategy[](2);
    strategies[0] = mpStrategy1;
    strategies[1] = mpStrategy2;

    mpCore.unauthorizeStrategies(strategies);

    assertEq(mpCore.authorizedStrategies(mpStrategy1), false);
    assertEq(mpCore.authorizedStrategies(mpStrategy2), false);
    vm.stopPrank();

    vm.prank(actionCreatorAaron);
    vm.expectRevert(LlamaCore.InvalidStrategy.selector);
    mpCore.createAction(
      uint8(Roles.ActionCreator), mpStrategy1, address(mockProtocol), 0, abi.encodeCall(MockProtocol.pause, (true))
    );
  }
}

contract CreateAccounts is LlamaCoreTest {
  function testFuzz_RevertIf_CallerIsNotLlama(address caller) public {
    vm.assume(caller != address(mpCore));
    vm.expectRevert(LlamaCore.OnlyLlama.selector);
    string[] memory newAccounts = Solarray.strings("LlamaAccount2", "LlamaAccount3", "LlamaAccount4");

    vm.prank(caller);
    mpCore.createAccounts(newAccounts);
  }

  function test_CreateNewAccounts() public {
    string[] memory newAccounts = Solarray.strings("LlamaAccount2", "LlamaAccount3", "LlamaAccount4");
    LlamaAccount[] memory accountAddresses = new LlamaAccount[](3);

    for (uint256 i; i < newAccounts.length; i++) {
      accountAddresses[i] = lens.computeLlamaAccountAddress(address(accountLogic), newAccounts[i], address(mpCore));
    }

    vm.expectEmit();
    emit AccountCreated(accountAddresses[0], newAccounts[0]);
    vm.expectEmit();
    emit AccountCreated(accountAddresses[1], newAccounts[1]);
    vm.expectEmit();
    emit AccountCreated(accountAddresses[2], newAccounts[2]);

    vm.prank(address(mpCore));
    mpCore.createAccounts(newAccounts);
  }

  function test_RevertIf_Reinitialized() public {
    string[] memory newAccounts = Solarray.strings("LlamaAccount2", "LlamaAccount3", "LlamaAccount4");
    LlamaAccount[] memory accountAddresses = new LlamaAccount[](3);

    for (uint256 i; i < newAccounts.length; i++) {
      accountAddresses[i] = lens.computeLlamaAccountAddress(address(accountLogic), newAccounts[i], address(mpCore));
    }

    vm.startPrank(address(mpCore));
    mpCore.createAccounts(newAccounts);

    vm.expectRevert(bytes("Initializable: contract is already initialized"));
    accountAddresses[0].initialize(newAccounts[0]);

    vm.expectRevert(bytes("Initializable: contract is already initialized"));
    accountAddresses[1].initialize(newAccounts[1]);

    vm.expectRevert(bytes("Initializable: contract is already initialized"));
    accountAddresses[2].initialize(newAccounts[2]);
  }

  function test_RevertIf_AccountsAreIdentical() public {
    string[] memory newAccounts = Solarray.strings("LlamaAccount1", "LlamaAccount1");
    vm.prank(address(mpCore));
    vm.expectRevert("ERC1167: create2 failed");
    mpCore.createAccounts(newAccounts);
  }

  function test_RevertIf_IdenticalAccountIsAlreadyDeployed() public {
    string[] memory newAccounts1 = Solarray.strings("LlamaAccount1");
    string[] memory newAccounts2 = Solarray.strings("LlamaAccount1");
    vm.startPrank(address(mpCore));
    mpCore.createAccounts(newAccounts1);

    vm.expectRevert("ERC1167: create2 failed");
    mpCore.createAccounts(newAccounts2);
  }

  function test_CanBeCalledByASuccessfulAction() public {
    string memory name = "LlamaAccount1";
    address actionCreatorAustin = makeAddr("actionCreatorAustin");
    string[] memory newAccounts = Solarray.strings(name);

    vm.prank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.TestRole2), actionCreatorAustin, DEFAULT_ROLE_QTY, DEFAULT_ROLE_EXPIRATION);

    LlamaAccount accountAddress = lens.computeLlamaAccountAddress(address(accountLogic), name, address(mpCore));

    bytes memory data = abi.encodeCall(LlamaCore.createAccounts, (newAccounts));
    vm.prank(actionCreatorAustin);
    uint256 actionId = mpCore.createAction(uint8(Roles.TestRole2), mpStrategy1, address(mpCore), 0, data);
    ActionInfo memory actionInfo = ActionInfo(actionId, actionCreatorAustin, mpStrategy1, address(mpCore), 0, data);

    vm.warp(block.timestamp + 1);

    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    mpCore.queueAction(actionInfo);

    vm.warp(block.timestamp + 5 days);

    vm.expectEmit();
    emit AccountCreated(accountAddress, name);
    mpCore.executeAction(actionInfo);
  }
}

contract SetGuard is LlamaCoreTest {
  event ActionGuardSet(address indexed target, bytes4 indexed selector, IActionGuard actionGuard);

  function testFuzz_RevertIf_CallerIsNotLlama(address caller, address target, bytes4 selector, IActionGuard guard)
    public
  {
    vm.assume(caller != address(mpCore));
    vm.expectRevert(LlamaCore.OnlyLlama.selector);
    vm.prank(caller);
    mpCore.setGuard(target, selector, guard);
  }

  function testFuzz_UpdatesGuardAndEmitsActionGuardSetEvent(address target, bytes4 selector, IActionGuard guard) public {
    vm.assume(target != address(mpCore) && target != address(mpPolicy));
    vm.prank(address(mpCore));
    vm.expectEmit();
    emit ActionGuardSet(target, selector, guard);
    mpCore.setGuard(target, selector, guard);
    assertEq(address(mpCore.actionGuard(target, selector)), address(guard));
  }

  function testFuzz_RevertIf_TargetIsCore(bytes4 selector, IActionGuard guard) public {
    vm.prank(address(mpCore));
    vm.expectRevert(LlamaCore.CannotUseCoreOrPolicy.selector);
    mpCore.setGuard(address(mpCore), selector, guard);
  }

  function testFuzz_RevertIf_TargetIsPolicy(bytes4 selector, IActionGuard guard) public {
    vm.prank(address(mpCore));
    vm.expectRevert(LlamaCore.CannotUseCoreOrPolicy.selector);
    mpCore.setGuard(address(mpPolicy), selector, guard);
  }
}

contract AuthorizeScript is LlamaCoreTest {
  event ScriptAuthorized(address indexed script, bool authorized);

  function testFuzz_RevertIf_CallerIsNotLlama(address caller, address script, bool authorized) public {
    vm.assume(caller != address(mpCore));
    vm.expectRevert(LlamaCore.OnlyLlama.selector);
    vm.prank(caller);
    mpCore.authorizeScript(script, authorized);
  }

  function testFuzz_UpdatesScriptMappingAndEmitsScriptAuthorizedEvent(address script, bool authorized) public {
    vm.assume(script != address(mpCore) && script != address(mpPolicy));
    vm.prank(address(mpCore));
    vm.expectEmit();
    emit ScriptAuthorized(script, authorized);
    mpCore.authorizeScript(script, authorized);
    assertEq(mpCore.authorizedScripts(script), authorized);
  }

  function testFuzz_RevertIf_ScriptIsCore(bool authorized) public {
    vm.prank(address(mpCore));
    vm.expectRevert(LlamaCore.CannotUseCoreOrPolicy.selector);
    mpCore.authorizeScript(address(mpCore), authorized);
  }

  function testFuzz_RevertIf_ScriptIsPolicy(bool authorized) public {
    vm.prank(address(mpCore));
    vm.expectRevert(LlamaCore.CannotUseCoreOrPolicy.selector);
    mpCore.authorizeScript(address(mpPolicy), authorized);
  }
}

contract GetActionState is LlamaCoreTest {
  function testFuzz_RevertsOnInvalidAction(ActionInfo calldata actionInfo) public {
    vm.expectRevert(LlamaCore.InfoHashMismatch.selector);
    mpCore.getActionState(actionInfo);
  }

  function test_CanceledActionsHaveStateCanceled() public {
    ActionInfo memory actionInfo = _createAction();
    vm.prank(actionCreatorAaron);
    mpCore.cancelAction(actionInfo);

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 canceledState = uint256(ActionState.Canceled);
    assertEq(currentState, canceledState);
  }

  function test_UnpassedActionsPriorToApprovalPeriodEndHaveStateActive() public {
    address actionCreatorAustin = makeAddr("actionCreatorAustin");

    vm.startPrank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.TestRole2), actionCreatorAustin, DEFAULT_ROLE_QTY, DEFAULT_ROLE_EXPIRATION);
    vm.stopPrank();

    vm.prank(actionCreatorAustin);
    uint256 actionId = mpCore.createAction(
      uint8(Roles.TestRole2), mpStrategy2, address(mockProtocol), 0, abi.encodeCall(MockProtocol.pause, (true))
    );

    ActionInfo memory actionInfo = ActionInfo(
      actionId, actionCreatorAustin, mpStrategy2, address(mockProtocol), 0, abi.encodeCall(MockProtocol.pause, (true))
    );

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 activeState = uint256(ActionState.Active);
    assertEq(currentState, activeState);
  }

  function test_ApprovedActionsWithFixedLengthHaveStateActive() public {
    ActionInfo memory actionInfo = _createAction();
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 1 days);

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 activeState = uint256(ActionState.Active);
    assertEq(currentState, activeState);
  }

  function test_PassedActionsPriorToApprovalPeriodEndHaveStateApproved() public {
    address actionCreatorAustin = makeAddr("actionCreatorAustin");

    vm.startPrank(address(mpCore));
    mpPolicy.setRoleHolder(uint8(Roles.TestRole2), actionCreatorAustin, DEFAULT_ROLE_QTY, DEFAULT_ROLE_EXPIRATION);
    vm.stopPrank();

    vm.prank(actionCreatorAustin);
    uint256 actionId = mpCore.createAction(
      uint8(Roles.TestRole2), mpStrategy2, address(mockProtocol), 0, abi.encodeCall(MockProtocol.pause, (true))
    );
    vm.warp(block.timestamp + 1);

    ActionInfo memory actionInfo = ActionInfo(
      actionId, actionCreatorAustin, mpStrategy2, address(mockProtocol), 0, abi.encodeCall(MockProtocol.pause, (true))
    );

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 activeState = uint256(ActionState.Active);
    assertEq(currentState, activeState);

    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);
    _approveAction(approverAndy, actionInfo);

    currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 approvedState = uint256(ActionState.Approved);
    assertEq(currentState, approvedState);
  }

  function testFuzz_ApprovedActionsHaveStateApproved(uint256 _timeSinceCreation) public {
    ActionInfo memory actionInfo = _createAction();
    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    uint256 approvalEndTime = toRelativeStrategy(actionInfo.strategy).approvalEndTime(actionInfo);
    vm.assume(_timeSinceCreation < toRelativeStrategy(mpStrategy1).approvalPeriod() * 2);
    vm.warp(block.timestamp + _timeSinceCreation);

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 expectedState = uint256(block.timestamp < approvalEndTime ? ActionState.Active : ActionState.Approved);
    assertEq(currentState, expectedState);
  }

  function test_QueuedActionsHaveStateQueued() public {
    ActionInfo memory actionInfo = _createAction();

    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
    _queueAction(actionInfo);

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 queuedState = uint256(ActionState.Queued);
    assertEq(currentState, queuedState);
  }

  function test_ExecutedActionsHaveStateExecuted() public {
    ActionInfo memory actionInfo = _createAction();

    _approveAction(approverAdam, actionInfo);
    _approveAction(approverAlicia, actionInfo);

    vm.warp(block.timestamp + 6 days);

    assertEq(mpStrategy1.isActionApproved(actionInfo), true);
    _queueAction(actionInfo);

    _disapproveAction(disapproverDave, actionInfo);

    vm.warp(block.timestamp + 5 days);

    _executeAction(actionInfo);

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 executedState = uint256(ActionState.Executed);
    assertEq(currentState, executedState);
  }

  function test_RejectedActionsHaveStateFailed() public {
    ActionInfo memory actionInfo = _createAction();
    vm.warp(block.timestamp + 12 days);

    uint256 currentState = uint256(mpCore.getActionState(actionInfo));
    uint256 failedState = uint256(ActionState.Failed);
    assertEq(currentState, failedState);
  }
}

contract LlamaCoreHarness is LlamaCore {
  function infoHash_exposed(ActionInfo calldata actionInfo) external pure returns (bytes32) {
    return _infoHash(actionInfo);
  }

  function infoHash_exposed(
    uint256 id,
    address creator,
    ILlamaStrategy strategy,
    address target,
    uint256 value,
    bytes calldata data
  ) external pure returns (bytes32) {
    return _infoHash(id, creator, strategy, target, value, data);
  }
}

contract InfoHash is LlamaCoreTest {
  LlamaCoreHarness llamaCoreHarness;

  function setUp() public override {
    llamaCoreHarness = new LlamaCoreHarness();
  }

  function testFuzz_InfoHashMethodsAreEquivalent(ActionInfo calldata actionInfo) public {
    bytes32 infoHash1 = llamaCoreHarness.infoHash_exposed(actionInfo);
    bytes32 infoHash2 = llamaCoreHarness.infoHash_exposed(
      actionInfo.id, actionInfo.creator, actionInfo.strategy, actionInfo.target, actionInfo.value, actionInfo.data
    );
    assertEq(infoHash1, infoHash2);
  }
}
