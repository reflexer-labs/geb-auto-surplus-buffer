pragma solidity ^0.5.15;

import "ds-test/test.sol";

import "./AutoBuffer.sol";

contract AutoBufferTest is DSTest {
    AutoBuffer autoBuffer;

    function setUp() public {
        autoBuffer = new AutoBuffer(address(0), address(0), 1);
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
