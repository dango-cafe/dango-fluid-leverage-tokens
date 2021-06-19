//SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import { SafeMathUpgradeable } from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";

/**
 * @title DangoMath
 * @author Dango.Cafe
 *
 * Taken from ds-math
 */
contract DangoMath {

    uint constant WAD = 10 ** 18;
    uint constant RAY = 10 ** 27;

    function wmul(uint x, uint y) internal pure returns (uint z) {
        z = SafeMathUpgradeable.add(SafeMathUpgradeable.mul(x, y), WAD / 2) / WAD;
    }

    function wdiv(uint x, uint y) internal pure returns (uint z) {
        z = SafeMathUpgradeable.add(SafeMathUpgradeable.mul(x, WAD), y / 2) / y;
    }
}