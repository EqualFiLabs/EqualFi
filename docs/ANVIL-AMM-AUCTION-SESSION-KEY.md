# Anvil: Create AMM Auction via Session Key (Position #1)

> **Scope:** Local Anvil only. This uses the **default Anvil dev owner key** to set owner‑only policies and approvals. On real networks, those steps must be signed by the actual owner wallet.

## Context (this dev deploy)
- **Diamond:** `0x3c15538ed063e688c8df3d571cb7a0062d2fb18d`
- **PositionNFT:** `0xccf1769d8713099172642eb55ddffc0c5a444fe9`
- **Position #1 TBA:** `0x6402bd4fb673a46a6926cc9be9f854cc4dcc8cfa`
- **SessionKeyValidationModule:** `0x87006e75a5B6bE9D1bbF61AC8Cd84f05D9140589`
- **Session key (label `position-1`):** `0xc13dB88f836FC64c8Bb024237E936738A933540c`

## Why these steps are required
- `AmmAuctionFacet.createAuction` checks **Position NFT ownership/approval** (`NotNFTOwner`)
- Session key needs **policy allowance** for `createAuction` selector
- Session key must be **funded for gas**
- TBA needs an **AMM policy** (duration/fee bounds) or calls will revert

## Step 1 — Ensure TBA is pointing at the diamond
```bash
cast call --rpc-url http://127.0.0.1:8545 \
  0x6402bd4fb673a46a6926cc9be9f854cc4dcc8cfa "getDiamond()"
```
Expected: `0x3c15538ed063e688c8df3d571cb7a0062d2fb18d`

## Step 2 — Set AMM policy on the TBA (owner‑only)
```bash
OWNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
TBA=0x6402bd4fb673a46a6926cc9be9f854cc4dcc8cfa

cast send --rpc-url http://127.0.0.1:8545 --private-key $OWNER_PK $TBA \
  "setAuctionPolicy((bool,bool,bool,uint64,uint64,uint16,uint16,uint256,uint256,uint256,uint256))" \
  "(true,true,false,0,2592000,0,0,0,0,0,0)"
```

## Step 3 — Allow AMM selectors on the session key (owner‑only)
```bash
OWNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
MODULE=0x87006e75a5B6bE9D1bbF61AC8Cd84f05D9140589
TBA=0x6402bd4fb673a46a6926cc9be9f854cc4dcc8cfa
KEY=0xc13dB88f836FC64c8Bb024237E936738A933540c

# Allowed selectors: createAuction, cancelAuction, rollYieldToPosition
cast send --rpc-url http://127.0.0.1:8545 --private-key $OWNER_PK $MODULE \
  "setSessionKeyPolicy(address,uint32,address,uint48,uint48,uint256,uint256,address[],bytes4[],(address,bytes4[])[])" \
  $TBA 7 $KEY 0 0 0 0 "[]" "[0xed5b5ef5,0x96b5a755,0xc88d8213]" "[]"
```

## Step 4 — Approve Position NFT #1 to the TBA (owner‑only)
```bash
OWNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
NFT=0xccf1769d8713099172642eb55ddffc0c5a444fe9
TBA=0x6402bd4fb673a46a6926cc9be9f854cc4dcc8cfa

cast send --rpc-url http://127.0.0.1:8545 --private-key $OWNER_PK $NFT \
  "approve(address,uint256)" $TBA 1
```

## Step 5 — Fund the session key (for gas)
```bash
OWNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
KEY=0xc13dB88f836FC64c8Bb024237E936738A933540c

cast send --rpc-url http://127.0.0.1:8545 --private-key $OWNER_PK $KEY --value 0.2ether
```

## Step 6 — Execute createAuction via session key
```bash
cd /home/hooftly/.openclaw/workspace/Projects/equalfi-ski
node - <<'NODE'
const { loadSessionWallet, executeWithRuntimeValidation } = require('./lib/session');
const { Interface, JsonRpcProvider } = require('ethers');

(async () => {
  const rpcUrl = 'http://127.0.0.1:8545';
  const provider = new JsonRpcProvider(rpcUrl);
  const tbaAddress = '0x6402bd4fb673a46a6926cc9be9f854cc4dcc8cfa';
  const sessionKeyModule = '0x87006e75a5B6bE9D1bbF61AC8Cd84f05D9140589';

  const iface = new Interface([
    'function createAuction((uint256 positionId,uint256 poolIdA,uint256 poolIdB,uint256 reserveA,uint256 reserveB,uint64 startTime,uint64 endTime,uint16 feeBps,uint8 feeAsset)) returns (uint256)'
  ]);

  const positionId = 1n;
  const poolIdA = 1n; // rETH
  const poolIdB = 5n; // USDC
  const reserveA = 5n * 10n**18n;
  const reserveB = 13000n * 10n**6n;
  const latest = await provider.getBlock('latest');
  const startTime = BigInt(latest.timestamp);
  const endTime = startTime + 30n * 24n * 60n * 60n;
  const feeBps = 30;
  const feeAsset = 0; // TokenIn

  const data = iface.encodeFunctionData('createAuction', [{
    positionId,
    poolIdA,
    poolIdB,
    reserveA,
    reserveB,
    startTime,
    endTime,
    feeBps,
    feeAsset,
  }]);

  const sessionWallet = await loadSessionWallet('position-1');
  const tx = await executeWithRuntimeValidation({
    rpcUrl,
    tbaAddress,
    moduleAddress: sessionKeyModule,
    entityId: 7,
    data,
    value: 0n,
    sessionWallet,
  });

  console.log('Auction tx hash:', tx.hash);
})();
NODE
```

## Common failure causes
- **NotNFTOwner** (`0x21e303dc`) → PositionNFT not approved to TBA
- **SessionValidationFailed** → selector not allowed in session policy
- **Insufficient funds** → session key has no ETH
- **Policy disabled or out of bounds** → auction policy not set on TBA

## Successful tx (example)
- **Tx:** `0x4ca115f7ca32627d947920ad415e5ba15ad3597026ad2b8e18109cde162a5e23`
- **Start/End:** `1771484962` → `1774076962` (~30 days)
