// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HongbaoBox} from "../src/HongbaoBox.sol";

/// @dev Exercises the same-transaction factory pattern without requiring network state or environment.
contract FactoryProbe {
    function deploy(address imd) external returns (LaunchToken token, HongbaoBox box) {
        token = new LaunchToken{salt: keccak256("token")}();
        box = new HongbaoBox{salt: keccak256("application")}(imd);
        require(token.balanceOf(address(this)) == 1e27 && token.totalSupply() == 1e27, "launch supply changed");
    }
}

contract LaunchCompatibilityTest is Test {
    function testFactoryDeploymentOnEmptyChainPreservesSupplyAndHasBoundedRuntime() public {
        vm.chainId(4663);
        // Exact requester-supplied deployment argument. Its code is intentionally absent in this test.
        address imd = address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"));
        assertEq(imd.code.length, 0);
        FactoryProbe factory = new FactoryProbe();
        (LaunchToken token, HongbaoBox box) = factory.deploy(imd);
        assertEq(address(box.imd()), imd);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(box)), 0);
        _checkRuntime(address(token));
        _checkRuntime(address(box));
        (bool ok,) = address(box).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(box).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        (ok,) = address(box).call(abi.encodeWithSignature("initialize(address)", address(this)));
        assertFalse(ok);
        (ok,) = address(box).call(abi.encodeWithSignature("upgradeTo(address)", address(this)));
        assertFalse(ok);
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
