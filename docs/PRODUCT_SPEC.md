# Guild MVP 产品规格（v0.1，2026-10-13）

## 目标
一个够格参加 hackathon 的可演示 MVP：一笔 agent 之间的任务，从下单一直走到放款，并留下链上履约记录。只用测试网：首选 Monad testnet，备选 Base Sepolia。

## 角色
- Buyer agent：代表用户下单，可以用脚本或 CLI 模拟。
- Expert bot：接任务、交付制品，演示里是一个"设计 bot"。
- Verifier bot：按冻结的交付标准自动验收，MVP 由协议默认提供。
- User：最终 approve，或者开启 approve-for-me，按 verifier 的结果自动放款。

## 端到端演示场景
"做一个 Guild logo，预算 5 USDC（测试网），24 小时内交付。"
1. Buyer 用交付标准模版创建任务，Expert 接单并确认报价。双方同意后，标准的哈希冻结上链。
2. Buyer 把资金存入托管合约，状态变为 Funded。
3. Expert 交付。制品存在链下，链上只记内容哈希和 URI。
4. Verifier 按验收项逐条检查，把结果哈希和 pass/fail 上链。
5. pass 时由用户 approve，或在 approve-for-me 模式下自动放款；fail 时退款给 Buyer。MVP 不做仲裁，只预留一个 Disputed 状态。
6. 双方的履约记录写入 ERC-8004 Reputation Registry。

## 状态机
Created → Agreed（标准冻结）→ Funded → Delivered → Verified(pass/fail) → Released / Refunded
另有超时退款：Funded 之后过了 deadline 还没交付，Buyer 可以取回资金。Disputed 状态先预留，不实现。

## 交付标准模版（结构化，必须机器可读）
```json
{
  "task_type": "design.logo",
  "title": "string",
  "price": {"token": "USDC", "amount": "5"},
  "deadline": "ISO8601",
  "deliverables": [{"kind": "image/png", "min_size": "1024x1024", "count": 3}],
  "acceptance_criteria": [
    {"id": "c1", "type": "auto", "check": "file_format == png && size >= 1024"},
    {"id": "c2", "type": "llm", "check": "包含文字 'Guild'，风格简洁"}
  ],
  "approval_mode": "user | approve_for_me",
  "revisions": 1
}
```
- 冻结方法：对规范化后的 JSON 取 keccak256，存进合约的 specHash。
- task_type 和每条验收结果都要结构化保存，以后做 agent 自主发现会用到这些数据。

## 链上声誉（ERC-8004）
- Expert 和 Verifier 在 Identity Registry 里注册。
- 每单结束后写一条反馈，包括 task_type、金额、pass/fail、是否准时。
- MVP 不做加权和防刷，只保证数据真实写入、可以查询。

## 不做
判官投票、协议 token、token 转售、自主发现和搜索、议价 UI、多币种。

## 3 分钟演示脚本
1. 问题（20 秒）：普通用户的 agent 做不好专业任务，专家 bot 能做好，但两者之间缺少可信的交易方式。
2. 现场跑一遍场景，展示每一步的链上交易（2 分钟）。
3. 查看 Expert 的 ERC-8004 声誉，多了一条记录（20 秒）。
4. 路线图（20 秒）：判官兜底、自主发现、NEAR 版本。

## MVP 完成标准
- 测试网上端到端跑通一次，每一步都有交易哈希可查。
- 验收 fail 的分支能触发退款，超时也能退款。
- README 里写清楚怎么用一条命令复现。
