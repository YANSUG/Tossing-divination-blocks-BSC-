// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title 農曆新年擲筊遊戲 (Jiaobei Game) - 修正轉帳版
 * @dev 
 * 1. 修正: 將 deprecated 的 transfer 改為 call
 * 2. 安全: 防合約呼叫, 防同區塊刷
 * 3. 數值: 立筊 8倍, 最大下注 1/10 獎池
 */
contract JiaobeiGame {
    
    // ==========================================
    //      1. 參數設定與變數
    // ==========================================
    
    address public owner;
    address public nianPoolAddress; 
    
    uint256 public constant MIN_BET = 0.001 ether; 
    
    // 資金分配
    uint256 public constant FEE_REF = 5;      
    uint256 public constant FEE_NIAN = 10;    
    uint256 public constant FEE_STREAK = 10;  

    // 自動收租
    uint256 public minPoolReserve = 1 ether;        
    uint256 public lastHarvestTime;                 
    uint256 public constant HARVEST_INTERVAL = 4 hours; 
    uint256 public constant HARVEST_RATE = 1;       

    struct StreakInfo {
        uint256 currentStreak;  
        uint256 lastPlayTime;   
        uint256 lastPlayBlock;  
        uint256 nonce;          
    }
    
    mapping(address => StreakInfo) public userStreaks; 
    
    address public currentWeeklyWinner; 
    uint256 public highestStreak;       
    uint256 public streakPoolBalance;   

    // ==========================================
    //           2. 事件
    // ==========================================
    
    event GameResult(
        address indexed player, 
        string resultType,      
        uint256 payout,         
        uint256 rawRandom,      
        uint256 betAmount,      
        bytes32 gameHash        
    );
    
    event StreakUpdated(address indexed player, uint256 newStreak); 
    event WeeklyWinnerPaid(address indexed winner, uint256 amount); 
    event DevFeeHarvested(uint256 amount, uint256 time);            

    // ==========================================
    //           3. 初始化
    // ==========================================
    
    constructor(address _nianPool) {
        owner = msg.sender;
        nianPoolAddress = _nianPool;
        lastHarvestTime = block.timestamp;
    }

    modifier onlyHuman() {
        require(msg.sender == tx.origin, "No contracts allowed");
        _;
    }

    // ==========================================
    //           4. 核心遊戲邏輯
    // ==========================================
    
    function play(address referrer) external payable onlyHuman {
        // [防刷]
        require(userStreaks[msg.sender].lastPlayBlock != block.number, "One bet per block");
        
        userStreaks[msg.sender].lastPlayBlock = block.number;
        userStreaks[msg.sender].lastPlayTime = block.timestamp;
        userStreaks[msg.sender].nonce++; 

        // [下注檢查]
        require(msg.value >= MIN_BET, "Min bet is 0.001 BNB");
        
        uint256 totalBalance = address(this).balance;
        uint256 availableJiaobeiPool = 0;
        if (totalBalance > streakPoolBalance + msg.value) {
            availableJiaobeiPool = totalBalance - streakPoolBalance - msg.value;
        }

        if (availableJiaobeiPool > 0) {
            require(msg.value <= availableJiaobeiPool / 10, "Bet too large (Max 1/10 of pool)");
        } else {
            require(msg.value == MIN_BET, "Pool empty, start small");
        }

        // --- 資金分流 (修正 transfer 警告) ---
        uint256 refShare = (msg.value * FEE_REF) / 100;    
        uint256 nianShare = (msg.value * FEE_NIAN) / 100;  
        uint256 streakShare = (msg.value * FEE_STREAK) / 100; 
        
        // 1. 推薦人轉帳
        if (referrer != address(0) && referrer != msg.sender) {
            (bool success, ) = referrer.call{value: refShare}("");
            require(success, "Ref transfer failed");
        } else {
            streakShare += refShare; 
        }

        // 2. 年獸池轉帳
        if (nianPoolAddress != address(0)) {
            (bool success, ) = nianPoolAddress.call{value: nianShare}("");
            if(!success) {
                // 失敗則回流給 owner
                (bool sent, ) = owner.call{value: nianShare}("");
                require(sent, "Backup transfer failed");
            }
        } else {
            (bool sent, ) = owner.call{value: nianShare}("");
            require(sent, "Nian transfer failed");
        }

        streakPoolBalance += streakShare;
        
        // --- 生成隨機數 ---
        bytes32 prevBlockHash = blockhash(block.number - 1);
        
        bytes32 gameHash = keccak256(abi.encodePacked(
            prevBlockHash,
            block.timestamp, 
            block.prevrandao, 
            block.number,
            msg.sender, 
            streakPoolBalance,
            msg.value,
            userStreaks[msg.sender].nonce
        ));

        uint256 random = uint256(gameHash) % 10000;

        uint256 payout = 0;
        string memory resultType = "";
        bool isWin = false;

        // --- 機率判定 ---
        if (random < 3500) {
            resultType = "Yin Jiao";
            payout = 0;
            userStreaks[msg.sender].currentStreak = 0; 
        } 
        else if (random < 7500) {
            resultType = "Xiao Jiao";
            payout = (msg.value * 5) / 10; 
            userStreaks[msg.sender].currentStreak = 0; 
        } 
        else {
            if (random >= 9975) {
                resultType = "Li Jiao (CRITICAL)";
                payout = msg.value * 8; 
                isWin = true;
            } else {
                resultType = "Sheng Jiao";
                payout = msg.value * 2; 
                isWin = true;
            }
        }

        // --- 更新連勝榜 (先更新狀態，再發錢，更安全) ---
        if (isWin) {
            userStreaks[msg.sender].currentStreak++;
            if (userStreaks[msg.sender].currentStreak > highestStreak) {
                highestStreak = userStreaks[msg.sender].currentStreak;
                currentWeeklyWinner = msg.sender;
            }
            emit StreakUpdated(msg.sender, userStreaks[msg.sender].currentStreak);
        }

        // --- 發放獎勵 (修正 transfer 警告) ---
        if (payout > 0) {
            uint256 contractBalance = address(this).balance;
            if (contractBalance > streakPoolBalance) {
                uint256 available = contractBalance - streakPoolBalance;
                if (payout > available) payout = available;
                
                // 使用 call 發送獎勵
                (bool success, ) = msg.sender.call{value: payout}("");
                require(success, "Payout transfer failed");
            }
        }

        emit GameResult(msg.sender, resultType, payout, random, msg.value, gameHash);

        // --- 自動抽成 ---
        _autoHarvestDevFee();
    }

    // ==========================================
    //           5. 內部工具函數
    // ==========================================

    function _autoHarvestDevFee() internal {
        if (block.timestamp >= lastHarvestTime + HARVEST_INTERVAL) {
            
            uint256 totalBalance = address(this).balance;
            
            if (totalBalance > streakPoolBalance) {
                uint256 jiaobeiPool = totalBalance - streakPoolBalance;
                
                if (jiaobeiPool > minPoolReserve) {
                    uint256 fee = (jiaobeiPool * HARVEST_RATE) / 1000; 
                    if (fee > 0) {
                        lastHarvestTime = block.timestamp;
                        
                        // 修正 transfer 警告
                        (bool success, ) = owner.call{value: fee}("");
                        if (success) {
                            emit DevFeeHarvested(fee, block.timestamp);
                        }
                    }
                }
            }
        }
    }

    // ==========================================
    //           6. 管理功能
    // ==========================================
    
    function setNianAddress(address _addr) external {
        require(msg.sender == owner);
        nianPoolAddress = _addr;
    }
    
    function setMinReserve(uint256 _newReserve) external {
        require(msg.sender == owner);
        minPoolReserve = _newReserve;
    }

    function settleWeek() external {
        require(currentWeeklyWinner != address(0), "No winner");
        
        uint256 reward = (streakPoolBalance * 80) / 100;
        streakPoolBalance = streakPoolBalance - reward; 
        
        // 修正 transfer 警告
        (bool success, ) = currentWeeklyWinner.call{value: reward}("");
        require(success, "Winner transfer failed");

        emit WeeklyWinnerPaid(currentWeeklyWinner, reward);
        
        highestStreak = 0; 
        currentWeeklyWinner = address(0);
    }
    
    function deposit() external payable {
    }
    
    receive() external payable {}
}
