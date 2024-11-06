// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract FailedTransferFromMock is ERC20Mock {
    constructor(string memory name, string memory symbol, address initialAccount, uint256 initialBalance)
        ERC20Mock(name, symbol, initialAccount, initialBalance)
    {}

    function transferFrom(address, /*sender*/ address, /*recipient*/ uint256 /*amount*/ )
        public
        pure
        override
        returns (bool)
    {
        return false;
    }
}
