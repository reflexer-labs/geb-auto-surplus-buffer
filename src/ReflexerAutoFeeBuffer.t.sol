pragma solidity ^0.5.15;

import "ds-test/test.sol";

import "./ReflexerAutoFeeBuffer.sol";

contract ReflexerAutoFeeBufferTest is DSTest {
    ReflexerAutoFeeBuffer buffer;

    function setUp() public {
        buffer = new ReflexerAutoFeeBuffer();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
