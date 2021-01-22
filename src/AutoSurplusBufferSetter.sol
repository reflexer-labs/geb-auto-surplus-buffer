pragma solidity 0.6.7;

import "geb-treasury-reimbursement/IncreasingTreasuryReimbursement.sol";

abstract contract AccountingEngineLike {
    function surplusBuffer() virtual public view returns (uint256);
    function modifyParameters(bytes32, uint256) virtual external;
}
abstract contract SAFEEngineLike {
    function globalDebt() virtual external view returns (uint256);
}

contract AutoSurplusBufferSetter is IncreasingTreasuryReimbursement {
    // --- Variables ---
    // Delay between updates after which the reward starts to increase
    uint256 public updateDelay;
    // The minimum buffer that must be maintained
    uint256 public minimumBufferSize;                                                           // [rad]
    // The max buffer allowed
    uint256 public maximumBufferSize;                                                           // [rad]
    // Last read global debt
    uint256 public lastRecordedGlobalDebt;                                                      // [rad]
    // Minimum change compared to current globalDebt that allows a new modifyParameters() call
    uint256 public minimumGlobalDebtChange;                                                     // [thousand]
    // Percentage of global debt that should be covered by the buffer
    uint256 public coveredDebt;                                                                 // [thousand]
    // Last timestamp when the median was updated
    uint256 public lastUpdateTime;                                                              // [unix timestamp]

    SAFEEngineLike       public safeEngine;
    AccountingEngineLike public accountingEngine;

    constructor(
      address treasury_,
      address safeEngine_,
      address accountingEngine_,
      uint256 minimumBufferSize_,
      uint256 minimumGlobalDebtChange_,
      uint256 coveredDebt_,
      uint256 updateDelay_,
      uint256 baseUpdateCallerReward_,
      uint256 maxUpdateCallerReward_,
      uint256 perSecondCallerRewardIncrease_
    ) public IncreasingTreasuryReimbursement(treasury_, baseUpdateCallerReward_, maxUpdateCallerReward_, perSecondCallerRewardIncrease_) {
        require(both(minimumGlobalDebtChange_ > 0, minimumGlobalDebtChange_ <= THOUSAND), "AutoSurplusBufferSetter/invalid-debt-change");
        require(both(coveredDebt_ > 0, coveredDebt_ <= THOUSAND), "AutoSurplusBufferSetter/invalid-covered-debt");
        require(updateDelay_ > 0, "AutoSurplusBufferSetter/null-update-delay");

        minimumBufferSize        = minimumBufferSize_;
        maximumBufferSize        = uint(-1);
        coveredDebt              = coveredDebt_;
        minimumGlobalDebtChange  = minimumGlobalDebtChange_;
        updateDelay              = updateDelay_;

        safeEngine               = SAFEEngineLike(safeEngine_);
        accountingEngine         = AccountingEngineLike(accountingEngine_);

        emit ModifyParameters(bytes32("minimumBufferSize"), minimumBufferSize);
        emit ModifyParameters(bytes32("maximumBufferSize"), maximumBufferSize);
        emit ModifyParameters(bytes32("coveredDebt"), coveredDebt);
        emit ModifyParameters(bytes32("minimumGlobalDebtChange"), minimumGlobalDebtChange);
        emit ModifyParameters(bytes32("accountingEngine"), address(accountingEngine));
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
      assembly{ z := and(x, y)}
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "minimumBufferSize") minimumBufferSize = val;
        else if (parameter == "maximumBufferSize") {
          require(val >= minimumBufferSize, "AutoSurplusBufferSetter/max-buffer-size-too-small");
          maximumBufferSize = val;
        }
        else if (parameter == "minimumGlobalDebtChange") {
          require(both(val > 0, val <= THOUSAND), "AutoSurplusBufferSetter/invalid-debt-change");
          minimumGlobalDebtChange = val;
        }
        else if (parameter == "coveredDebt") {
          require(both(val > 0, val <= THOUSAND), "AutoSurplusBufferSetter/invalid-covered-debt");
          coveredDebt = val;
        }
        else if (parameter == "baseUpdateCallerReward") {
          baseUpdateCallerReward = val;
        }
        else if (parameter == "maxUpdateCallerReward") {
          require(val > baseUpdateCallerReward, "AutoSurplusBufferSetter/invalid-max-reward");
          maxUpdateCallerReward = val;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(val >= RAY, "AutoSurplusBufferSetter/invalid-reward-increase");
          perSecondCallerRewardIncrease = val;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(val > 0, "AutoSurplusBufferSetter/invalid-max-increase-delay");
          maxRewardIncreaseDelay = val;
        }
        else if (parameter == "updateDelay") {
          require(val > 0, "AutoSurplusBufferSetter/null-update-delay");
          updateDelay = val;
        }
        else revert("AutoSurplusBufferSetter/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "AutoSurplusBufferSetter/null-address");
        if (parameter == "accountingEngine") accountingEngine = AccountingEngineLike(addr);
        else if (parameter == "treasury") treasury = StabilityFeeTreasuryLike(addr);
        else revert("AutoSurplusBufferSetter/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Math ---
    uint internal constant RAD      = 10 ** 45;
    uint internal constant THOUSAND = 1000;

    // --- Utils ---
    function percentageDebtChange(uint currentGlobalDebt) public view returns (uint) {
        if (lastRecordedGlobalDebt == 0) return uint(-1);
        uint deltaDebt = (currentGlobalDebt >= lastRecordedGlobalDebt) ?
          subtract(currentGlobalDebt, lastRecordedGlobalDebt) : subtract(lastRecordedGlobalDebt, currentGlobalDebt);
        return multiply(deltaDebt, THOUSAND) / lastRecordedGlobalDebt;
    }
    function calculateNewBuffer(uint currentGlobalDebt) public view returns (uint newBuffer) {
        if (currentGlobalDebt >= uint(-1) / coveredDebt) return maximumBufferSize;
        newBuffer = multiply(coveredDebt, currentGlobalDebt) / THOUSAND;
        newBuffer = both(newBuffer > maximumBufferSize, maximumBufferSize > 0) ? maximumBufferSize : newBuffer;
        newBuffer = (newBuffer < minimumBufferSize) ? minimumBufferSize : newBuffer;
    }

    // --- Buffer Adjustment ---
    function adjustSurplusBuffer(address feeReceiver) external {
        // Check delay between calls
        require(either(subtract(now, lastUpdateTime) >= updateDelay, lastUpdateTime == 0), "AutoSurplusBufferSetter/wait-more");
        // Get the caller's reward
        uint256 callerReward = getCallerReward(lastUpdateTime, updateDelay);
        // Store the timestamp of the update
        lastUpdateTime = now;

        // Get the current global debt
        uint currentGlobalDebt = safeEngine.globalDebt();
        // Check if we didn't already reach the max buffer
        if (both(currentGlobalDebt > lastRecordedGlobalDebt, maximumBufferSize > 0)) {
          require(accountingEngine.surplusBuffer() < maximumBufferSize, "AutoSurplusBufferSetter/max-buffer-reached");
        }
        // Check that global debt changed enough
        require(percentageDebtChange(currentGlobalDebt) >= subtract(THOUSAND, minimumGlobalDebtChange), "AutoSurplusBufferSetter/small-debt-change");
        // Compute the new buffer
        uint newBuffer         = calculateNewBuffer(currentGlobalDebt);

        lastRecordedGlobalDebt = currentGlobalDebt;
        accountingEngine.modifyParameters("surplusBuffer", newBuffer);

        // Pay the caller for updating the rate
        rewardCaller(feeReceiver, callerReward);
    }
}
