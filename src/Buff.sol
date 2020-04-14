pragma solidity ^0.5.15;

contract VowLike {
    function hump() external view returns (uint);
    function file(bytes32, uint) external;
}

contract VatLike {
    function debt() external view returns (uint);
}

contract Buff {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Buff/not-authorized");
        _;
    }

    uint256 public min;  // minimum buffer                                                   [rad]
    uint256 public max;  // maximum buffer                                                   [rad]
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
        require(min_ > 0, "Buff/null-minimum");
        wards[msg.sender] = 1;
        min = min_;
        max = uint(-1);
        vat = VatLike(vat_);
        vow = VowLike(vow_);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 val) external note auth {
        require(val > 0, "Buff/null-val");
        if (what == "min") min = val;
        else if (what == "max") {
          require(val >= min, "Buff/max-too-small");
          max = val;
        }
        else if (what == "cut") cut = val;
        else if (what == "trim") trim = val;
        else revert("Buff/file-unrecognized-param");
    }
    function file(bytes32 what, address addr) external note auth {
        require(addr != address(0), "Buff/null-addr");
        if (what == "vat") vat = VatLike(addr);
        else if (what == "vow") vow = VowLike(addr);
        else revert("Buff/file-unrecognized-param");
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
    function order(uint x, uint y) internal pure returns (uint a, uint b) {
        (a, b) = (x >= y) ? (x, y) : (y, x);
    }
    function delta(uint cur, uint past) internal view returns (bool) {
        (uint x, uint y) = order(cur, past);
        if (past == 0) return true;
        return mul(sub(x, y), THOUSAND) / (past / WAD) >= trim;
    }

    // --- Buffer Adjustment ---
    function adjust() external {
        uint cur   = mul(cut, vat.debt()) / THOUSAND;
        uint past  = vow.hump();
        uint hump_ = (both(cur > min, delta(cur, past))) ? cur : past;
        hump_      = (both(max != uint(-1), hump_ > max)) ? max : hump_;
        hump_      = (cur < min) ? min : cur;
        vow.file("hump", hump_);
    }
}
