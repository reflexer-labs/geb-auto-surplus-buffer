pragma solidity ^0.5.15;

contract VowLike {
    function hump() external view returns (uint);
    function file(bytes32, uint) external;
}

contract VatLike {
    function debt() external view returns (uint);
}

contract AutoBuffer {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "AutoBuffer/not-authorized");
        _;
    }

    uint256 public min;  // minimum buffer
    uint256 public trim; // minimum change compared to current hump that triggers a new file
    uint256 public cut;  // percentage of debt that should be covered by the buffer

    VatLike public vat;
    VowLike public vow;

    modifier note {
        _;
        assembly {
            // log an 'anonymous' event with a constant 6 words of calldata
            // and four indexed topics: the selector and the first three args
            let mark := msize                         // end of memory ensures zero
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
      address vat_,
      address vow_,
      uint256 min_
    ) public {
        require(min_ > 0, "AutoBuffer/null-minimum");
        wards[msg.sender] = 1;
        min = min_;
        vat = VatLike(vat_);
        vow = VowLike(vow_);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 val) external note auth {
        require(val > 0, "AutoBuffer/null-val");
        if (what == "min") min = val;
        else if (what == "cut") cut = val;
        else if (what == "trim") trim = val;
        else revert("AutoBuffer/file-unrecognized-param");
    }
    function file(bytes32 what, address addr) external note auth {
        require(addr != address(0), "AutoBuffer/null-addr");
        if (what == "vat") vat = VatLike(addr);
        else if (what == "vow") vow = VowLike(addr);
        else revert("AutoBuffer/file-unrecognized-param");
    }

    // --- Math ---
    uint constant RAY = 10 ** 27;
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
    function order(uint x, uint y) internal pure returns (uint a, uint b) {
        (a, b) = (x >= y) ? (x, y) : (y, x);
    }
    function delta(uint x, uint y) internal view returns (bool) {
        (uint a, uint b) = order(x, y);
        return sub(a, b) >= trim;
    }

    // --- Buffer Adjustment ---
    function adjust() external {
        uint cur   = mul(cut, vat.debt()) / RAY;
        uint past  = vow.hump();
        uint hump_ = (both(cur > min, delta(cur, past))) ? cur : past;
        hump_      = (hump_ < min) ? min : hump_;
        vow.file("hump", hump_);
    }
}
