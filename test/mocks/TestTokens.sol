// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Burns 1% on every transfer, so the escrow receives less than `amount`.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev Calls back into `target` on every outgoing transfer once armed, recording the revert data.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bytes public lastRevertData;
    bool public reentered;

    constructor() ERC20("Reentrant Token", "REENTER") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && from == target) {
            address t = target;
            target = address(0);
            reentered = true;
            (bool ok, bytes memory data) = t.call(payload);
            if (!ok) lastRevertData = data;
        }
    }
}
