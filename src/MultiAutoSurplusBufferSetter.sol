pragma solidity 0.6.7;

import "geb-treasury-reimbursement/reimbursement/multi/MultiIncreasingTreasuryReimbursement.sol";

abstract contract AccountingEngineLike {
    function surplusBuffer(bytes32) virtual public view returns (uint256);
    function modifyParameters(bytes32, bytes32, uint256) virtual external;
}
abstract contract SAFEEngineLike {
    function globalDebt(bytes32) virtual external view returns (uint256);
}

contract MultiAutoSurplusBufferSetter is MultiIncreasingTreasuryReimbursement {
    // --- Variables ---
    // Whether buffer adjustments are blocked or not
    uint256 public stopAdjustments;
    // Delay between updates after which the reward starts to increase
    uint256 public updateDelay;                                                                 // [seconds]
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

    // Safe engine contract
    SAFEEngineLike       public safeEngine;
    // Accounting engine contract
    AccountingEngineLike public accountingEngine;

    constructor(
      bytes32 coinName_,
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
    ) public MultiIncreasingTreasuryReimbursement(coinName_, treasury_, baseUpdateCallerReward_, maxUpdateCallerReward_, perSecondCallerRewardIncrease_) {
        require(both(minimumGlobalDebtChange_ > 0, minimumGlobalDebtChange_ <= THOUSAND), "MultiAutoSurplusBufferSetter/invalid-debt-change");
        require(both(coveredDebt_ > 0, coveredDebt_ <= THOUSAND), "MultiAutoSurplusBufferSetter/invalid-covered-debt");
        require(updateDelay_ > 0, "MultiAutoSurplusBufferSetter/null-update-delay");

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
    /*
    * @notify Modify an uint256 parameter
    * @param parameter The name of the parameter to change
    * @param val The new parameter value
    */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "minimumBufferSize") minimumBufferSize = val;
        else if (parameter == "maximumBufferSize") {
          require(val >= minimumBufferSize, "MultiAutoSurplusBufferSetter/max-buffer-size-too-small");
          maximumBufferSize = val;
        }
        else if (parameter == "minimumGlobalDebtChange") {
          require(both(val > 0, val <= THOUSAND), "MultiAutoSurplusBufferSetter/invalid-debt-change");
          minimumGlobalDebtChange = val;
        }
        else if (parameter == "coveredDebt") {
          require(both(val > 0, val <= THOUSAND), "MultiAutoSurplusBufferSetter/invalid-covered-debt");
          coveredDebt = val;
        }
        else if (parameter == "baseUpdateCallerReward") {
          require(val <= maxUpdateCallerReward, "MultiAutoSurplusBufferSetter/invalid-min-reward");
          baseUpdateCallerReward = val;
        }
        else if (parameter == "maxUpdateCallerReward") {
          require(val >= baseUpdateCallerReward, "MultiAutoSurplusBufferSetter/invalid-max-reward");
          maxUpdateCallerReward = val;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(val >= RAY, "MultiAutoSurplusBufferSetter/invalid-reward-increase");
          perSecondCallerRewardIncrease = val;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(val > 0, "MultiAutoSurplusBufferSetter/invalid-max-increase-delay");
          maxRewardIncreaseDelay = val;
        }
        else if (parameter == "updateDelay") {
          require(val > 0, "MultiAutoSurplusBufferSetter/null-update-delay");
          updateDelay = val;
        }
        else if (parameter == "stopAdjustments") {
          require(val <= 1, "MultiAutoSurplusBufferSetter/invalid-stop-adjust");
          stopAdjustments = val;
        }
        else revert("MultiAutoSurplusBufferSetter/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /*
    * @notify Modify an address param
    * @param parameter The name of the parameter to change
    * @param addr The new address for the parameter
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "MultiAutoSurplusBufferSetter/null-address");
        if (parameter == "accountingEngine") accountingEngine = AccountingEngineLike(addr);
        else if (parameter == "treasury") treasury = StabilityFeeTreasuryLike(addr);
        else revert("MultiAutoSurplusBufferSetter/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Math ---
    uint internal constant RAD      = 10 ** 45;
    uint internal constant THOUSAND = 1000;

    // --- Utils ---
    /*
    * @notify Return the percentage debt change since the last recorded debt amount in the system
    * @param currentGlobalDebt The current globalDebt in the system
    */
    function percentageDebtChange(uint currentGlobalDebt) public view returns (uint256) {
        if (lastRecordedGlobalDebt == 0) return uint(-1);
        uint256 deltaDebt = (currentGlobalDebt >= lastRecordedGlobalDebt) ?
          subtract(currentGlobalDebt, lastRecordedGlobalDebt) : subtract(lastRecordedGlobalDebt, currentGlobalDebt);
        return multiply(deltaDebt, THOUSAND) / lastRecordedGlobalDebt;
    }
    /*
    * @notify Return the upcoming surplus buffer
    * @param currentGlobalDebt The current amount of debt in the system
    * @return newBuffer The new surplus buffer
    */
    function getNewBuffer(uint256 currentGlobalDebt) public view returns (uint newBuffer) {
        if (currentGlobalDebt >= uint(-1) / coveredDebt) return maximumBufferSize;
        newBuffer = multiply(coveredDebt, currentGlobalDebt) / THOUSAND;
        newBuffer = both(newBuffer > maximumBufferSize, maximumBufferSize > 0) ? maximumBufferSize : newBuffer;
        newBuffer = (newBuffer < minimumBufferSize) ? minimumBufferSize : newBuffer;
    }

    // --- Buffer Adjustment ---
    /*
    * @notify Calculate and set a new surplus buffer
    * @param feeReceiver The address that will receive the SF reward for calling this function
    */
    function adjustSurplusBuffer(address feeReceiver) external {
        // Check if adjustments are forbidden or not
        require(stopAdjustments == 0, "MultiAutoSurplusBufferSetter/cannot-adjust");
        // Check delay between calls
        require(either(subtract(now, lastUpdateTime) >= updateDelay, lastUpdateTime == 0), "MultiAutoSurplusBufferSetter/wait-more");
        // Get the caller's reward
        uint256 callerReward = getCallerReward(lastUpdateTime, updateDelay);
        // Store the timestamp of the update
        lastUpdateTime = now;

        // Get the current global debt
        uint currentGlobalDebt = safeEngine.globalDebt(coinName);
        // Check if we didn't already reach the max buffer
        if (both(currentGlobalDebt > lastRecordedGlobalDebt, maximumBufferSize > 0)) {
          require(accountingEngine.surplusBuffer(coinName) < maximumBufferSize, "MultiAutoSurplusBufferSetter/max-buffer-reached");
        }
        // Check that global debt changed enough
        require(percentageDebtChange(currentGlobalDebt) >= subtract(THOUSAND, minimumGlobalDebtChange), "MultiAutoSurplusBufferSetter/small-debt-change");
        // Compute the new buffer
        uint newBuffer         = getNewBuffer(currentGlobalDebt);

        lastRecordedGlobalDebt = currentGlobalDebt;
        accountingEngine.modifyParameters(coinName, "surplusBuffer", newBuffer);

        // Pay the caller for updating the rate
        rewardCaller(feeReceiver, callerReward);
    }
}
