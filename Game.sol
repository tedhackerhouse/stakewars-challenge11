// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IAuroraStNear.sol";
import "./interfaces/IBastionDepositor.sol";
import "./interfaces/IBastionLens.sol";
import "./interfaces/IBastionRewardClaimer.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Game is Ownable {
    using SafeMath for uint256;

    /* ========== EVENTS ========== */
    event BuyCell(address indexed user, uint256 x, uint256 y);
    event Attack(
        address indexed attacker,
        address indexed defender,
        uint256 x,
        uint256 y,
        bool success
    );
    event FeeDistributed(
        address indexed user,
        uint256 x,
        uint256 y,
        uint256 stNearAmount
    );
    event Harvested(uint256 x, uint256 y, uint256 harvested);
    event MetaRewardBalanceChanged(uint256 amount);
    event ClaimReward(address indexed user, uint256 amount);

    /* ========== DATA STRUCTURES ========== */
    struct Cell {
        uint256 x;
        uint256 y;
        address owner;
        int256 soldierCount;
        uint256 stNearStakedAmount;
        uint256 metaReward;
    }

    struct Coordinate {
        uint256 x;
        uint256 y;
    }

    // Mapping x and y axis to cell
    mapping(uint256 => mapping(uint256 => Cell)) public cellInfo;

    // Mapping owner address to owned cells
    mapping(address => Coordinate[]) public coordinatesByUser;

    /* ========== Member variables ========== */
    address constant PROTOCOL = address(0);
    uint256 constant CELL_PRICE = 10**22;
    uint256 constant ATTACK_PRICE = 10**22;
    uint256 constant SOLDIER_PRICE = 10**22;
    int256 constant MAX_AMOUNT_OF_SOLDIERS = 10;
    uint256 private constant MAX_INT = 2**256 - 1;
    uint8 public constant AREA_INDEX = 10;
    uint256 private constant INITIAL_DISTRIBUTION = 10**22; // 0.01 wNEAR

    address private constant W_NEAR =
        0xC42C30aC6Cc15faC9bD938618BcaA1a1FaE8501d;
    address private constant metaToken =
        0xc21Ff01229e982d7c8b8691163B0A3Cb8F357453;
    address private constant bastionDeposit =
        0xB76108eb764b4427505c4bb020A37D95b3ef5AFE;
    address private constant bastionRewardClaim =
        0xd7A812a5d2CC96e78C83B0324c82269EE82aF1c8;
    address private constant bastionLens =
        0x90ECC01EE12f38b4DDf57ddB077e44CE1B51f3c7;
    address private constant stNEARToken =
        0x07F9F7f963C5cD2BBFFd30CcfB964Be114332E30;
    address private constant cstNEARToken =
        0xB76108eb764b4427505c4bb020A37D95b3ef5AFE;
    address private constant auroraStNear =
        0x534BACf1126f60EA513F796a3377ff432BE62cf9;
    uint256 public lastMetaRewardBalance;

    uint256 public totalStNearStakedAmount;

    constructor() {}

    function buyCell(uint256 x, uint256 y) public {
        uint256 cellBalances = cellBalancesByAddress(msg.sender);
        require(cellBalances == 0, "Not available to cell-owned user");

        Cell storage cell = cellInfo[x][y];
        require(cell.owner == PROTOCOL, "Cell is owned by other user");

        IERC20(W_NEAR).transferFrom(msg.sender, address(this), CELL_PRICE);

        _rebaseFeeForMetaReward(CELL_PRICE);
        cell.owner = msg.sender;
        cell.soldierCount = 1;
        coordinatesByUser[msg.sender].push(Coordinate(x, y));

        emit BuyCell(msg.sender, x, y);
    }

    function attack(
        uint256 from_x,
        uint256 from_y,
        uint256 to_x,
        uint256 to_y
    ) public returns (bool success) {
        Cell storage fromCell = cellInfo[from_x][from_y];
        address attacker = fromCell.owner;
        Cell storage toCell = cellInfo[to_x][to_y];
        address defender = toCell.owner;

        require(msg.sender == attacker, "Only owner can attack");
        require(attacker != defender, "Can't attack oneself");
        require(fromCell.soldierCount > 0, "No soldiers to attack");

        IERC20(W_NEAR).transferFrom(msg.sender, address(this), ATTACK_PRICE);
        _rebaseFeeForMetaReward(ATTACK_PRICE);
        (
            bool result,
            int256 attackers_left,
            int256 defenders_left
        ) = battleResult(fromCell.soldierCount, toCell.soldierCount);

        success = result;
        fromCell.soldierCount = attackers_left;
        toCell.soldierCount = defenders_left;

        if (success) {
            if (toCell.owner != PROTOCOL) {
                removeCell(toCell.owner, to_x, to_y);
            }
            toCell.owner = attacker;
            coordinatesByUser[attacker].push(Coordinate(to_x, to_y));
        }

        emit Attack(attacker, defender, to_x, to_y, success);

        return success;
    }

    function increaseSoldier(uint256 x, uint256 y) public {
        Cell storage cell = cellInfo[x][y];

        require(msg.sender == cell.owner, "Only owner can increase soldier");
        require(
            cell.soldierCount < MAX_AMOUNT_OF_SOLDIERS,
            "Can't increase more"
        );

        IERC20(W_NEAR).transferFrom(msg.sender, address(this), SOLDIER_PRICE);
        _rebaseFeeForMetaReward(SOLDIER_PRICE);

        cell.soldierCount += 1;
    }

    function cellBalancesByAddress(address owner)
        public
        view
        returns (uint256)
    {
        require(owner != address(0), "Balance query for the zero address");
        return coordinatesByUser[owner].length;
    }

    function cellOwnerByCoordinate(uint256 x, uint256 y)
        public
        view
        returns (address)
    {
        address owner = cellInfo[x][y].owner;
        require(owner != address(0), "Owner query for the zero address");
        return owner;
    }

    function randomKeccak256(uint256 _modulus) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp))) % _modulus;
    }

    function battleResult(int256 attackers, int256 defenders)
        internal
        view
        returns (
            bool result,
            int256 attackers_left,
            int256 defenders_left
        )
    {
        uint256 rand = randomKeccak256(100);
        int256 diff = attackers - defenders;
        int256 factor = int256(rand) + (diff * 10);

        if (diff >= -4 && diff <= 4) {
            result = factor >= 50;
        } else if (diff <= -5) {
            result = rand > 96;
        } else if (diff >= 5) {
            result = rand > 2;
        }

        if (result) {
            attackers_left = attackers / 3 + 1;
            defenders_left = 1;
        } else {
            attackers_left = 0;
            defenders_left = defenders / 3 + 1;
        }

        return (result, attackers_left, defenders_left);
    }

    function removeCell(
        address owner,
        uint256 x,
        uint256 y
    ) internal {
        Coordinate[] storage coordinates = coordinatesByUser[owner];

        for (uint256 i = 0; i < coordinates.length; i++) {
            if (coordinates[i].x == x && coordinates[i].y == y) {
                coordinates[i] = coordinates[coordinates.length - 1];
                break;
            }
        }
        coordinates.pop();
    }

    function _rebaseFeeForMetaReward(uint256 nearAmount) internal {

        uint256 totalMetaRewards = _getTotalMetaRewards();
        Cell[] memory ownedCells = getCellsByUser(msg.sender);

        for (uint256 i = 0; i < ownedCells.length; i++) {
            uint256 reward = getHarvestReward(ownedCells[i].x, ownedCells[i].y);
            Cell storage cell = cellInfo[ownedCells[i].x][ownedCells[i].y];
            cell.metaReward = reward;
        }
        lastMetaRewardBalance = totalMetaRewards;

        emit MetaRewardBalanceChanged(lastMetaRewardBalance);

        uint256 increasedStNear = _stakeToBastion(nearAmount);
        distributeStNEAR(increasedStNear);
    }

    function claimReward(uint256 x, uint256 y) public {
        uint256 claimableReward = getHarvestReward(x, y);
        Cell storage cell = cellInfo[x][y];
        require(
            cell.owner == msg.sender,
            "Messsage sender should be owner of the cell."
        );

        uint256 ownedMeta = IERC20(metaToken).balanceOf(address(this));
        if (ownedMeta < claimableReward) {
            IBastionRewardClaimer(bastionRewardClaim).claimReward(
                1,
                address(this)
            );
            uint256 afterHarvest = IERC20(metaToken).balanceOf(address(this));
            uint256 harvested = afterHarvest.sub(ownedMeta);
            emit Harvested(x, y, harvested);
        }

        IERC20(metaToken).transfer(msg.sender, claimableReward);
        cell.metaReward = 0;
        emit ClaimReward(msg.sender, claimableReward);

        lastMetaRewardBalance = _getTotalMetaRewards();
        emit MetaRewardBalanceChanged(lastMetaRewardBalance);
    }

    function manualStakeForAllCell(uint256 nearAmount) public onlyOwner {
        IERC20(W_NEAR).transferFrom(msg.sender, address(this), nearAmount);
        uint256 increasedStNear = _stakeToBastion(nearAmount);

        for (uint256 i = 0; i < AREA_INDEX; i++) {
            for (uint256 j = 0; j < AREA_INDEX; j++) {
                Cell storage cell = cellInfo[i][j];
                cell.x = i;
                cell.y = j;
                cell.soldierCount = cell.owner == address(0)
                    ? int256(3)
                    : cell.soldierCount;
                cell.stNearStakedAmount +=
                    increasedStNear /
                    (AREA_INDEX * AREA_INDEX);
                cell.owner = cell.owner != address(0)
                    ? cell.owner
                    : address(0);
            }
        }
    }

    function distributeStNEAR(uint256 stNearAmount) internal {

        for (uint256 i = 0; i < 5; i++) {
            uint256 x = randomKeccak256(AREA_INDEX);
            uint256 y = randomKeccak256(AREA_INDEX);
            Cell storage cell = cellInfo[x][y];

            uint256 distributedAmountPerCell = (stNearAmount * 20) / 100;
            cell.stNearStakedAmount = cell.stNearStakedAmount.add(
                distributedAmountPerCell
            );

            emit FeeDistributed(
                msg.sender,
                cell.x,
                cell.y,
                distributedAmountPerCell
            );
        }
    }

    function getHarvestReward(uint256 x, uint256 y)
        public
        view
        returns (uint256)
    {
        uint256 totalMetaRewards = _getTotalMetaRewards();
        Cell memory cell = cellInfo[x][y];
        uint256 rewardEmissionPerCell = _getEmissionRewardPerCell(
            totalMetaRewards.sub(lastMetaRewardBalance),
            cell.stNearStakedAmount
        );
        return rewardEmissionPerCell.add(cell.metaReward);
    }

    function getCellsByUser(address account)
        public
        view
        returns (Cell[] memory)
    {
        Coordinate[] memory coordinates = coordinatesByUser[account];
        Cell[] memory cells = new Cell[](coordinates.length);

        for (uint256 i = 0; i < coordinates.length; i++) {
            cells[i] = cellInfo[coordinates[i].x][coordinates[i].y];
        }
        return cells;
    }

    function _stakeToBastion(uint256 nearAmount)
        internal
        returns (uint256 increasedStNear)
    {
        uint256 before = IERC20(stNEARToken).balanceOf(address(this));

        _approveIfNeeded(W_NEAR, auroraStNear);
        IAuroraStNear(auroraStNear).swapwNEARForstNEAR(nearAmount);

        uint256 _increasedStNear = IERC20(stNEARToken).balanceOf(
            address(this)
        ) - before;
        totalStNearStakedAmount += _increasedStNear;

        _approveIfNeeded(stNEARToken, bastionDeposit);
        IBastionDepositor(bastionDeposit).mint(_increasedStNear);

        return _increasedStNear;
    }

    function _getTotalMetaRewards() public view returns (uint256) {
        IBastionLens.CTokenBalances memory balances = IBastionLens(bastionLens)
            .cTokenBalances(cstNEARToken, address(this), 2);

        uint256 currentPendingRewardEstimate = balances
            .rewardBalances[1]
            .rewardEstimate;
        uint256 currentPendingRewardAccrue = balances
            .rewardBalances[1]
            .rewardAccrue;

        return
            currentPendingRewardEstimate +
            currentPendingRewardAccrue +
            IERC20(metaToken).balanceOf(address(this));
    }

    function _getEmissionRewardPerCell(
        uint256 difference,
        uint256 stnearAmountPerCell
    ) internal view returns (uint256) {
        uint256 result = difference.mul(stnearAmountPerCell).div(
            totalStNearStakedAmount
        );
        return result;
    }

    function _approveIfNeeded(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), address(spender)) == 0) {
            IERC20(token).approve(address(spender), type(uint256).max);
        }
    }
}
