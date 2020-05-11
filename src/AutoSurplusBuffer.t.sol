pragma solidity ^0.5.15;

import "ds-test/test.sol";

import "./AutoSurplusBuffer.sol";

contract AccountingEngine is AccountingEngineLike {
    uint public surplusBuffer;

    constructor(uint surplusBuffer_) public {
        surplusBuffer = surplusBuffer_;
    }

    function modifyParameters(bytes32 parameter, uint val) external {
        if (parameter == "surplusBuffer") surplusBuffer = val;
        else revert("AccountingEngine/modify-unrecognized-param");
    }
}

contract CDPEngine is CDPEngineLike {
    uint public globalDebt;

    constructor(uint globalDebt_) public {
        globalDebt = globalDebt_;
    }

    function modifyParameters(bytes32 parameter, uint val) external {
        globalDebt = val;
    }
}

contract AutoSurplusBufferTest is DSTest {
    AutoSurplusBuffer autoSurplusBuffer;
    CDPEngine cdpEngine;
    AccountingEngine accountingEngine;

    function setUp() public {
        cdpEngine = new CDPEngine(rad(50 ether));
        accountingEngine = new AccountingEngine(0);
        autoSurplusBuffer = new AutoSurplusBuffer(
          address(cdpEngine),
          address(accountingEngine),
          rad(10 ether),
          100,
          500
        );
    }

    uint constant RAY     = 10 ** 27;
    uint constant HUNDRED = 10 ** 47;

    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }
    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }

    function testFail_set_max_surplus_lower_than_min() public {
        autoSurplusBuffer.modifyParameters("maximumBufferSize", rad(10 ether) - 1);
    }
    function test_min_surplus_zero() public {
        accountingEngine = new AccountingEngine(rad(50 ether));
        autoSurplusBuffer = new AutoSurplusBuffer(
          address(cdpEngine),
          address(accountingEngine),
          0,
          100,
          500
        );

        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(25 ether));
    }
    function test_zero_debt_change() public {
        accountingEngine = new AccountingEngine(rad(50 ether));
        autoSurplusBuffer = new AutoSurplusBuffer(
          address(cdpEngine),
          address(accountingEngine),
          0,
          100,
          500
        );

        autoSurplusBuffer.adjustSurplusBuffer();
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(25 ether));
    }
    function test_zero_covered_debt() public {
        accountingEngine = new AccountingEngine(rad(50 ether));
        autoSurplusBuffer = new AutoSurplusBuffer(
          address(cdpEngine),
          address(accountingEngine),
          0,
          100,
          0
        );

        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), 0);
    }
    function test_not_change_if_small_debt_change() public {
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(25 ether));

        cdpEngine.modifyParameters("globalDebt", rad(54 ether));
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(25 ether));

        cdpEngine.modifyParameters("globalDebt", rad(49 ether));
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(25 ether));
    }
    function test_change_if_big_debt_change() public {
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(25 ether));

        cdpEngine.modifyParameters("globalDebt", rad(54 ether));
        autoSurplusBuffer.adjustSurplusBuffer();

        cdpEngine.modifyParameters("globalDebt", rad(55 ether));
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(27.5 ether));

        cdpEngine.modifyParameters("globalDebt", rad(21 ether));
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(10.5 ether));
    }
    function test_cannot_go_below_min() public {
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(25 ether));

        cdpEngine.modifyParameters("globalDebt", rad(15 ether));
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(10 ether));
    }
    function test_cannot_go_above_max() public {
        autoSurplusBuffer.modifyParameters("maximumBufferSize", rad(20 ether));
        cdpEngine.modifyParameters("globalDebt", rad(54 ether));
        autoSurplusBuffer.adjustSurplusBuffer();
        assertEq(accountingEngine.surplusBuffer(), rad(20 ether));
    }
}
