pragma solidity ^0.6.7;

abstract contract AccountingEngineLike {
    function modifyParameters(bytes32, uint256) virtual external;
}
abstract contract SAFEEngineLike {
    function globalDebt() virtual external view returns (uint256);
}
abstract contract StabilityFeeTreasuryLike {
    function getAllowance(address) virtual external view returns (uint, uint);
    function systemCoin() virtual external view returns (address);
    function pullFunds(address, address, uint) virtual external;
}

contract AutoSurplusBuffer {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "AutoSurplusBuffer/account-not-authorized");
        _;
    }

    // Delay between updates after which the reward starts to increase
    uint256 public updateDelay;
    // Starting reward for the feeReceiver
    uint256 public baseUpdateCallerReward;                                                      // [wad]
    // Max possible reward for the feeReceiver
    uint256 public maxUpdateCallerReward;                                                       // [wad]
    // Max delay taken into consideration when calculating the adjusted reward
    uint256 public maxRewardIncreaseDelay;                                                      // [seconds]
    // Rate applied to baseUpdateCallerReward every extra second passed beyond updateDelay seconds since the last update call
    uint256 public perSecondCallerRewardIncrease;                                               // [ray]
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

    SAFEEngineLike           public safeEngine;
    AccountingEngineLike     public accountingEngine;
    StabilityFeeTreasuryLike public treasury;

    // --- Events ---
    event ModifyParameters(bytes32 parameter, address addr);
    event ModifyParameters(bytes32 parameter, uint256 data);
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event RewardCaller(address feeReceiver, uint256 amount);
    event FailRewardCaller(bytes revertReason, address finalFeeReceiver, uint256 reward);

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
    ) public {
        require(both(minimumGlobalDebtChange_ > 0, minimumGlobalDebtChange_ <= THOUSAND), "AutoSurplusBuffer/invalid-debt-change");
        require(both(coveredDebt_ > 0, coveredDebt_ <= THOUSAND), "AutoSurplusBuffer/invalid-covered-debt");
        require(maxUpdateCallerReward_ > baseUpdateCallerReward_, "AutoSurplusBuffer/invalid-max-reward");
        require(perSecondCallerRewardIncrease_ >= RAY, "AutoSurplusBuffer/invalid-reward-increase");
        require(updateDelay_ > 0, "AutoSurplusBuffer/null-update-delay");

        authorizedAccounts[msg.sender] = 1;
        minimumBufferSize              = minimumBufferSize_;
        maximumBufferSize              = uint(-1);
        coveredDebt                    = coveredDebt_;
        minimumGlobalDebtChange        = minimumGlobalDebtChange_;
        baseUpdateCallerReward         = baseUpdateCallerReward_;
        maxUpdateCallerReward          = maxUpdateCallerReward_;
        perSecondCallerRewardIncrease  = perSecondCallerRewardIncrease_;
        updateDelay                    = updateDelay_;
        maxRewardIncreaseDelay         = uint(-1);

        treasury                       = StabilityFeeTreasuryLike(treasury_);
        safeEngine                     = SAFEEngineLike(safeEngine_);
        accountingEngine               = AccountingEngineLike(accountingEngine_);

        emit AddAuthorization(msg.sender);
        emit ModifyParameters(bytes32("minimumBufferSize"), minimumBufferSize);
        emit ModifyParameters(bytes32("maximumBufferSize"), maximumBufferSize);
        emit ModifyParameters(bytes32("coveredDebt"), coveredDebt);
        emit ModifyParameters(bytes32("minimumGlobalDebtChange"), minimumGlobalDebtChange);
        emit ModifyParameters(bytes32("treasury"), treasury_);
        emit ModifyParameters(bytes32("safeEngine"), address(safeEngine));
        emit ModifyParameters(bytes32("accountingEngine"), address(accountingEngine));
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
      assembly{ z := and(x, y)}
    }
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "minimumBufferSize") minimumBufferSize = val;
        else if (parameter == "maximumBufferSize") {
          require(val >= minimumBufferSize, "AutoSurplusBuffer/max-buffer-size-too-small");
          maximumBufferSize = val;
        }
        else if (parameter == "minimumGlobalDebtChange") {
          require(both(val > 0, val <= THOUSAND), "AutoSurplusBuffer/invalid-debt-change");
          minimumGlobalDebtChange = val;
        }
        else if (parameter == "coveredDebt") {
          require(both(val > 0, val <= THOUSAND), "AutoSurplusBuffer/invalid-covered-debt");
          coveredDebt = val;
        }
        else if (parameter == "baseUpdateCallerReward") {
          baseUpdateCallerReward = val;
        }
        else if (parameter == "maxUpdateCallerReward") {
          require(val > baseUpdateCallerReward, "AutoSurplusBuffer/invalid-max-reward");
          maxUpdateCallerReward = val;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(val >= RAY, "AutoSurplusBuffer/invalid-reward-increase");
          perSecondCallerRewardIncrease = val;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(val > 0, "AutoSurplusBuffer/invalid-max-increase-delay");
          maxRewardIncreaseDelay = val;
        }
        else if (parameter == "updateDelay") {
          require(val > 0, "AutoSurplusBuffer/null-update-delay");
          updateDelay = val;
        }
        else revert("AutoSurplusBuffer/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "AutoSurplusBuffer/null-address");
        if (parameter == "accountingEngine") accountingEngine = AccountingEngineLike(addr);
        else if (parameter == "treasury") treasury = StabilityFeeTreasuryLike(addr);
        else revert("AutoSurplusBuffer/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Math ---
    uint internal constant WAD      = 10 ** 18;
    uint internal constant RAY      = 10 ** 27;
    uint internal constant RAD      = 10 ** 45;
    uint internal constant THOUSAND = 1000;
    function minimum(uint x, uint y) internal pure returns (uint z) {
        z = (x <= y) ? x : y;
    }
    function addition(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function subtract(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function wmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / WAD;
    }
    function rmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / RAY;
    }
    function rpower(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    // --- Treasury Utils ---
    function treasuryAllowance() public view returns (uint256) {
        (uint total, uint perBlock) = treasury.getAllowance(address(this));
        return minimum(total, perBlock);
    }
    function getCallerReward() public view returns (uint256) {
        if (lastUpdateTime == 0) return baseUpdateCallerReward;
        uint256 timeElapsed = subtract(now, lastUpdateTime);
        if (timeElapsed < updateDelay) {
            return 0;
        }
        uint256 baseReward   = baseUpdateCallerReward;
        uint256 adjustedTime = subtract(timeElapsed, updateDelay);
        if (adjustedTime > 0) {
            adjustedTime = (adjustedTime > maxRewardIncreaseDelay) ? maxRewardIncreaseDelay : adjustedTime;
            baseReward = rmultiply(rpower(perSecondCallerRewardIncrease, adjustedTime, RAY), baseReward);
        }
        uint256 maxReward = minimum(maxUpdateCallerReward, treasuryAllowance() / RAY);
        if (baseReward > maxReward) {
            baseReward = maxReward;
        }
        return baseReward;
    }
    function rewardCaller(address proposedFeeReceiver, uint256 reward) internal {
        if (address(treasury) == proposedFeeReceiver) return;
        if (either(address(treasury) == address(0), reward == 0)) return;
        address finalFeeReceiver = (proposedFeeReceiver == address(0)) ? msg.sender : proposedFeeReceiver;
        try treasury.pullFunds(finalFeeReceiver, treasury.systemCoin(), reward) {
            emit RewardCaller(finalFeeReceiver, reward);
        }
        catch(bytes memory revertReason) {
            emit FailRewardCaller(revertReason, finalFeeReceiver, reward);
        }
    }

    // --- Utils ---
    function percentageDebtChange(uint currentGlobalDebt) public view returns (uint) {
        if (lastRecordedGlobalDebt == 0) return uint(-1);
        uint deltaDebt = (currentGlobalDebt >= lastRecordedGlobalDebt) ?
          subtract(currentGlobalDebt, lastRecordedGlobalDebt) : subtract(lastRecordedGlobalDebt, currentGlobalDebt);
        return multiply(deltaDebt, THOUSAND) / lastRecordedGlobalDebt;
    }
    function calculateNewBuffer(uint currentGlobalDebt) public view returns (uint newBuffer) {
        uint debtToCover = multiply(coveredDebt, currentGlobalDebt) / THOUSAND;
        debtToCover      = (debtToCover > maximumBufferSize) ? maximumBufferSize : debtToCover;
        debtToCover      = (debtToCover < minimumBufferSize) ? minimumBufferSize : debtToCover;
    }

    // --- Buffer Adjustment ---
    function adjustSurplusBuffer(address feeReceiver) external {
        // Check delay between calls
        require(either(subtract(now, lastUpdateTime) >= updateDelay, lastUpdateTime == 0), "AutoSurplusBuffer/wait-more");
        // Get the caller's reward
        uint256 callerReward = getCallerReward();
        // Store the timestamp of the update
        lastUpdateTime = now;

        // Get the current global debt
        uint currentGlobalDebt = safeEngine.globalDebt();
        // Check that global debt changed enough
        require(percentageDebtChange(currentGlobalDebt) >= minimumGlobalDebtChange, "AutoSurplusBuffer/small-debt-change");
        // Compute the new buffer
        uint newBuffer         = calculateNewBuffer(currentGlobalDebt);

        lastRecordedGlobalDebt = currentGlobalDebt;
        accountingEngine.modifyParameters("surplusBuffer", newBuffer);

        // Pay the caller for updating the rate
        rewardCaller(feeReceiver, callerReward);
    }
}
