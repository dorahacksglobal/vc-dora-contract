// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.14;

library AddressUtils {
    function isNotContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size == 0;
    }
}

interface ERC20 {
    function decimals() external view returns (uint256);

    function transferFrom(
        address,
        address,
        uint256
    ) external returns (bool);

    function transfer(address, uint256) external returns (bool);
}

contract vcDORA {
    using AddressUtils for address;

    uint256 private constant WEEK = 1 weeks;
    uint256 private constant MAXTIME = 208 * WEEK; // 4 years

    enum LockedType {
        DEPOSIT_FOR_TYPE,
        CREATE_LOCK_TYPE,
        INCREASE_LOCK_AMOUNT,
        INCREASE_UNLOCK_TIME
    }

    struct Point {
        int256 bias;
        int256 slope;
        uint256 ts;
    }

    struct LockedBalance {
        uint256 amount;
        uint256 end; // 永远对齐一个 epoch 的开始时间
    }

    event Deposit(
        address indexed provider,
        uint256 amount,
        uint256 indexed locktime,
        LockedType lockedType,
        uint256 ts
    );

    event Withdraw(address indexed provider, uint256 value, uint256 ts);

    event Supply(uint256 prevSupply, uint256 supply);

    address public admin;

    string public name;
    string public symbol;
    uint256 public decimals;

    ERC20 public token;

    uint256 public supply;

    mapping(address => LockedBalance) public locked;

    // epoch := timestamp / WEEK
    uint256 public epoch;

    // epoch -> unsigned point
    mapping(uint256 => Point) public pointHistory;

    mapping(uint256 => int256) public slopeChanges;

    // user -> user_epoch -> Point
    mapping(address => mapping(uint256 => Point)) public userPointHistory;

    mapping(address => uint256) public userPointEpoch;

    // user -> ts -> balance
    mapping(address => mapping(uint256 => uint256)) public userBalanceSnapshot;

    bool _rentrancyLock;

    modifier nonReentrant() {
        require(!_rentrancyLock);
        _rentrancyLock = true;
        _;
        _rentrancyLock = false;
    }

    function init(
        ERC20 _token,
        string memory _name,
        string memory _symbol
    ) external {
        require(admin == address(0));
        admin = msg.sender;

        token = _token;
        decimals = _token.decimals();
        name = _name;
        symbol = _symbol;

        epoch = block.timestamp / WEEK;
        pointHistory[epoch].ts = block.timestamp;
    }

    function _posInterpolation(Point storage _p, uint256 _t)
        internal
        view
        returns (uint256)
    {
        int256 v = _p.bias - _p.slope * (int256(_t) - int256(_p.ts));
        if (v < 0) {
            return 0;
        } else {
            return uint256(v);
        }
    }

    function _checkPoint() internal returns (Point storage pointNow) {
        Point storage lastPoint = pointHistory[epoch];

        uint256 latestEpoch = block.timestamp / WEEK;

        for (uint256 i = 0; i < 255; i++) {
            if (epoch >= latestEpoch) {
                // 已经同步到最新高度
                break;
            }
            epoch++;

            int256 prevBias = lastPoint.bias;
            int256 prevSlope = lastPoint.slope;

            lastPoint = pointHistory[epoch];
            lastPoint.bias = prevBias - prevSlope * int256(WEEK);
            lastPoint.slope = prevSlope + slopeChanges[epoch];
            lastPoint.ts = epoch * WEEK;
        }

        return lastPoint;
    }

    function _checkUserPoint(
        address _user,
        LockedBalance storage _oldLocked,
        LockedBalance memory _newLocked
    ) internal {
        Point storage pointNow = _checkPoint();
        pointNow.bias -= pointNow.slope * int256(block.timestamp - pointNow.ts);
        pointNow.ts = block.timestamp;

        // require(_newLocked.end >= _oldLocked.end, "ALWAYS");
        // require(_newLocked.end >= block.timestamp, "ALWAYS");
        // require(_newLocked.amount >= _oldLocked.amount, "ALWAYS");

        if (_oldLocked.end > block.timestamp) {
            // old locked not ended
            int256 oldSlope = int256(_oldLocked.amount / MAXTIME);
            int256 oldBias = oldSlope *
                int256(_oldLocked.end - block.timestamp);

            pointNow.bias -= oldBias;
            pointNow.slope -= oldSlope;

            slopeChanges[_oldLocked.end] += oldSlope;
        }

        int256 newSlope = int256(_newLocked.amount / MAXTIME);
        int256 newBias = newSlope * int256(_newLocked.end - block.timestamp);

        pointNow.bias += newBias;
        pointNow.slope += newSlope;

        slopeChanges[_newLocked.end] -= newSlope;

        locked[_user] = _newLocked;
        uint256 uEpoch = userPointEpoch[_user] + 1;
        userPointEpoch[_user] = uEpoch;
        userPointHistory[_user][uEpoch] = Point(
            newBias,
            newSlope,
            block.timestamp
        );
    }

    function _depositFor(
        address _user,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance storage _locked,
        LockedType _type
    ) internal {
        uint256 prevSupply = supply;
        supply = prevSupply + _value;

        LockedBalance memory newLocked = LockedBalance(
            _locked.amount + _value,
            _unlockTime
        );

        _checkUserPoint(_user, _locked, newLocked);

        if (_value != 0) {
            require(
                token.transferFrom(_user, address(this), _value),
                'ERC20 transfer error'
            );
        }

        emit Deposit(_user, _value, _unlockTime, _type, block.timestamp);
        emit Supply(prevSupply, supply);
    }

    function depositFor(address _user, uint256 _value) external nonReentrant {
        LockedBalance storage _locked = locked[_user];

        require(_value > 0, 'invalid value');
        require(_locked.amount > 0, 'No existing lock found');
        require(
            _locked.end > block.timestamp,
            'Cannot add to expired lock. Withdraw'
        );

        _depositFor(
            _user,
            _value,
            _locked.end,
            _locked,
            LockedType.DEPOSIT_FOR_TYPE
        );
    }

    function createLock(uint256 _value, uint256 _unlockTime)
        external
        nonReentrant
    {
        require(msg.sender.isNotContract());

        _unlockTime = (_unlockTime / WEEK) * WEEK;

        LockedBalance storage _locked = locked[msg.sender];

        require(_value > 0, 'invalid value');
        require(_locked.amount == 0, 'Withdraw old tokens first');
        require(
            _unlockTime > block.timestamp,
            'Can only lock until time in the future'
        );
        require(
            _unlockTime <= block.timestamp + MAXTIME,
            'Voting lock can be 4 years max'
        );

        _depositFor(
            msg.sender,
            _value,
            _unlockTime,
            _locked,
            LockedType.CREATE_LOCK_TYPE
        );
    }

    function increaseAmount(uint256 _value) external nonReentrant {
        LockedBalance storage _locked = locked[msg.sender];

        require(_value > 0, 'invalid value');
        require(_locked.amount > 0, 'No existing lock found');
        require(
            _locked.end > block.timestamp,
            'Cannot add to expired lock. Withdraw'
        );

        _depositFor(
            msg.sender,
            _value,
            _locked.end,
            _locked,
            LockedType.INCREASE_LOCK_AMOUNT
        );
    }

    function increaseUnlockTime(uint256 _unlockTime) external nonReentrant {
        LockedBalance storage _locked = locked[msg.sender];

        require(_locked.amount > 0, 'No existing lock found');
        require(
            _locked.end > block.timestamp,
            'Cannot add to expired lock. Withdraw'
        );
        require(_unlockTime > _locked.end, 'Can only increase lock duration');
        require(
            _unlockTime <= block.timestamp + MAXTIME,
            'Voting lock can be 4 years max'
        );

        _depositFor(
            msg.sender,
            _locked.amount,
            _unlockTime,
            _locked,
            LockedType.INCREASE_UNLOCK_TIME
        );
    }

    function withdraw() external nonReentrant {
        LockedBalance storage _locked = locked[msg.sender];

        uint256 value = _locked.amount;

        uint256 prevSupply = supply;
        supply = prevSupply - value;

        LockedBalance memory _newLocked = LockedBalance(0, 0);

        _checkUserPoint(msg.sender, _locked, _newLocked);

        require(token.transfer(msg.sender, value));

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(prevSupply, supply);
    }

    function balanceSnapshot(address _user, uint256 _ts) external {
        userBalanceSnapshot[_user][_ts] = balanceOfAt(_user, _ts);
    }

    function balanceSnapshot(
        address _user,
        uint256 _ts,
        uint256 _uEpoch
    ) external {
        uint256 maxUserEpoch = userPointEpoch[_user];
        require(_uEpoch <= maxUserEpoch);

        uint256 maxTs = block.timestamp;
        if (_uEpoch != maxUserEpoch) {
            // not latest user epoch
            maxTs = userPointHistory[_user][_uEpoch + 1].ts;
        }

        require(_ts < maxTs);

        Point storage uPoint = userPointHistory[_user][_uEpoch];

        require(_ts >= uPoint.ts);

        userBalanceSnapshot[_user][_ts] = _posInterpolation(uPoint, _ts);
    }

    function balanceOf(address _user) external view returns (uint256) {
        uint256 uEpoch = userPointEpoch[_user];
        if (uEpoch == 0) {
            return 0;
        } else {
            Point storage uPoint = userPointHistory[_user][uEpoch];
            return _posInterpolation(uPoint, block.timestamp);
        }
    }

    function balanceOfAt(address _user, uint256 _ts)
        public
        view
        returns (uint256)
    {
        require(_ts < block.timestamp);

        uint256 snapshot = userBalanceSnapshot[_user][_ts];
        if (snapshot > 0) {
            return snapshot;
        }

        mapping(uint256 => Point) storage _userPointHistory = userPointHistory[
            _user
        ];
        uint256 min;
        uint256 mid;
        uint256 max = userPointEpoch[_user];
        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) {
                break;
            }
            mid = (min + max + 1) / 2;
            if (_userPointHistory[mid].ts <= _ts) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }

        Point storage uPoint = _userPointHistory[min];

        return _posInterpolation(uPoint, _ts);
    }

    function _supplyAt(Point storage _p, uint256 _ts)
        internal
        view
        returns (uint256)
    {
        int256 bias = _p.bias;
        int256 slope = _p.slope;
        uint256 ts = _p.ts;

        uint256 ti = (ts / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; i++) {
            ti += WEEK;
            if (ti > _ts) {
                // aim epoch
                ti = _ts;
            }
            bias -= slope * (int256(ti) - int256(ts));
            if (ti == _ts) {
                break;
            }
            slope += slopeChanges[ti];
            ts = ti;
        }

        return uint256(bias);
    }

    function totalSupply() external view returns (uint256) {
        Point storage lastPoint = pointHistory[epoch];
        return _supplyAt(lastPoint, block.timestamp);
    }

    function totalSupplyAt(uint256 _ts) external view returns (uint256) {
        require(_ts < block.timestamp);
        return totalSupplyAtFuture(_ts);
    }

    function totalSupplyAtFuture(uint256 _ts) public view returns (uint256) {
        if (_ts > block.timestamp + MAXTIME) {
            return 0;
        }
        uint256 targetEpoch = _ts / WEEK;
        if (targetEpoch > epoch) {
            targetEpoch = epoch;
        }
        Point storage targetPoint = pointHistory[targetEpoch];

        if (targetPoint.ts == 0) {
            return 0;
        } else {
            return _supplyAt(targetPoint, _ts);
        }
    }
}
