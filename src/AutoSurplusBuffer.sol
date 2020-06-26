pragma solidity ^0.6.7;

abstract contract AccountingEngineLike {
    function surplusBuffer() virtual external view returns (uint);
    function modifyParameters(bytes32,uint) virtual external;
}

abstract contract CDPEngineLike {
    function globalDebt() virtual external view returns (uint);
}

contract AutoSurplusBuffer {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external emitLog isAuthorized {
        require(contractEnabled == 1, "AutoSurplusBuffer/contract-not-enabled");
        authorizedAccounts[account] = 1;
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 0;
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "AutoSurplusBuffer/account-not-authorized");
        _;
    }

    uint256 public minimumBufferSize;  // minimum buffer                                     [rad]
    uint256 public maximumBufferSize;  // maximum buffer                                     [rad]
    uint256 public minimumDebtChange;  // minimum change compared to current hump that triggers a new modifyParameters() call
    uint256 public coveredDebt;        // percentage of debt that should be covered by the buffer
    uint256 public contractEnabled;

    CDPEngineLike public cdpEngine;
    AccountingEngineLike public accountingEngine;

    modifier emitLog {
        _;
        assembly {
            // log an 'anonymous' event with a constant 6 words of calldata
            // and four indexed topics: the selector and the first three args
            let mark := msize()                       // end of memory ensures zero
            mstore(0x40, add(mark, 288))              // update free memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 calldataload(4),                     // arg1
                 calldataload(36),                    // arg2
                 calldataload(68)                     // arg3
                )
        }
    }

    constructor(
      address cdpEngine_,
      address accountingEngine_,
      uint256 minimumBufferSize_,
      uint256 minimumDebtChange_,
      uint256 coveredDebt_
    ) public {
        require(minimumDebtChange_ <= THOUSAND, "AutoSurplusBuffer/debt-change-too-big");
        require(coveredDebt_ <= THOUSAND, "AutoSurplusBuffer/too-much-covered-debt");
        authorizedAccounts[msg.sender] = 1;
        minimumBufferSize = minimumBufferSize_;
        maximumBufferSize = uint(-1);
        coveredDebt = coveredDebt_;
        minimumDebtChange = minimumDebtChange_;
        cdpEngine = CDPEngineLike(cdpEngine_);
        accountingEngine = AccountingEngineLike(accountingEngine_);
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 val) external emitLog isAuthorized {
        require(val > 0, "AutoSurplusBuffer/null-value");
        if (parameter == "minimumBufferSize") minimumBufferSize = val;
        else if (parameter == "maximumBufferSize") {
          require(val >= minimumBufferSize, "AutoSurplusBuffer/max-buffer-size-too-small");
          maximumBufferSize = val;
        }
        else if (parameter == "minimumDebtChange") {
          require(val <= THOUSAND, "AutoSurplusBuffer/debt-change-too-big");
          minimumDebtChange = val;
        }
        else if (parameter == "coveredDebt") {
          require(val <= THOUSAND, "AutoSurplusBuffer/too-much-covered-debt");
          coveredDebt = val;
        }
        else revert("AutoSurplusBuffer/modify-unrecognized-param");
    }
    function modifyParameters(bytes32 parameter, address addr) external emitLog isAuthorized {
        require(addr != address(0), "AutoSurplusBuffer/null-address");
        if (parameter == "cdpEngine") cdpEngine = CDPEngineLike(addr);
        else if (parameter == "accountingEngine") accountingEngine = AccountingEngineLike(addr);
        else revert("AutoSurplusBuffer/modify-unrecognized-param");
    }

    // --- Math ---
    uint constant WAD      = 10 ** 18;
    uint constant RAD      = 10 ** 45;
    uint constant THOUSAND = 1000;
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y) }
    }

    // --- Utils ---
    function exceedsChange(uint currentBuffer, uint debtToCover) public pure returns (uint) {
        if (currentBuffer == 0) return uint(-1);

        (uint higherBuffer, uint lowerBuffer) =
          (currentBuffer >= debtToCover) ?
          (currentBuffer, debtToCover) : (debtToCover, currentBuffer);

        return (mul(sub(higherBuffer, lowerBuffer), THOUSAND) / currentBuffer);
    }
    function calculateNewBuffer() internal view returns (uint newBuffer) {
        uint debtToCover   = mul(coveredDebt, cdpEngine.globalDebt()) / THOUSAND;
        uint currentBuffer = accountingEngine.surplusBuffer();
        newBuffer          = (exceedsChange(currentBuffer, debtToCover) >= minimumDebtChange) ? debtToCover : currentBuffer;
        newBuffer          = (newBuffer <= minimumBufferSize) ? minimumBufferSize : newBuffer;
        newBuffer          = (newBuffer >= maximumBufferSize) ? maximumBufferSize : newBuffer;
    }

    // --- Buffer Adjustment ---
    function adjustSurplusBuffer() external emitLog {
        uint newBuffer = calculateNewBuffer();
        accountingEngine.modifyParameters("surplusBuffer", newBuffer);
    }
}
