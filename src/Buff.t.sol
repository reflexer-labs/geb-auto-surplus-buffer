pragma solidity ^0.5.15;

import "ds-test/test.sol";

import "./Buff.sol";

contract Vow is VowLike {
    uint public hump;

    constructor(uint hump_) public {
        hump = hump_;
    }

    function file(bytes32 what, uint val) external {
        if (what == "hump") hump = val;
        else revert("Vow/file-unrecognized-param");
    }
}

contract Vat is VatLike {
    uint public debt;

    constructor(uint debt_) public {
        debt = debt_;
    }

    function file(bytes32 what, uint val) external {
        debt = val;
    }
}

contract BuffTest is DSTest {
    Buff buff;
    Vat vat;
    Vow vow;

    function setUp() public {
        vat = new Vat(rad(100 ether));
        vow = new Vow(0);
        buff = new Buff(address(vat), address(vow), rad(10 ether));
    }

    uint constant RAY     = 10 ** 27;
    uint constant HUNDRED = 10 ** 47;

    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }
    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }

    function test_set_min_when_hump_too_small() public {
        assertEq(vow.hump(), 0);
        buff.adjust();
        assertEq(vow.hump(), rad(10 ether));
    }
    function test_all_system_stats_null() public {
        vat.file("debt", 0);
        buff.adjust();
        assertEq(vow.hump(), rad(10 ether));
    }
    function test_current_hump_bigger_than_min() public {
        vow.file("hump", rad(30 ether));
        buff.adjust();
        assertEq(vow.hump(), rad(10 ether));
    }
    function test_current_hump_smaller_than_min() public {
        vow.file("hump", rad(5 ether));
        buff.adjust();
        assertEq(vow.hump(), rad(10 ether));
    }
    function testFail_set_small_max() public {
        buff.file("max", rad(1 ether));
    }
    function test_set_proper_max() public {
        buff.file("max", rad(11 ether));
        assertEq(buff.max(), rad(11 ether));
    }
    function test_non_zero_cut() public {
        buff.file("cut", 200);
        assertEq(vat.debt(), rad(100 ether));
        assertEq(buff.cut(), 200);
        assertEq(vat.debt() * buff.cut() / 1000, rad(20 ether));
        buff.adjust();
        assertEq(vow.hump(), rad(20 ether));
    }
    function test_non_zero_trim() public {
        buff.file("trim", 50);
        buff.file("cut", 200);
        assertEq(vat.debt(), rad(100 ether));
        assertEq(buff.cut(), 200);
        assertEq(vat.debt() * buff.cut() / 1000, rad(20 ether));
        buff.adjust();
        assertEq(vow.hump(), rad(20 ether));

        vat.file("debt", rad(105 ether));
        buff.adjust();
        assertEq(vow.hump(), rad(21 ether));

        vat.file("debt", rad(40 ether));
        buff.adjust();
        assertEq(vow.hump(), rad(10 ether));

        vat.file("debt", rad(100000000000000000 ether));
        buff.adjust();
        assertEq(vow.hump(), rad(20000000000000000 ether));
    }
}
