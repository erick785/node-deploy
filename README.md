# Deployment tools of BSC


## Installation
Before proceeding to the next steps, please ensure that the following packages and softwares are well installed in your local machine: 
- nodejs: v16.15.0
- npm: 6.14.6
- go: 1.24+
- foundry
- python3 3.12.x
- poetry
- jq


## Quick Start
1. Clone this repository
```bash
git clone https://github.com/bnb-chain/node-deploy.git
```

2. For the first time, please execute the following command
```bash
pip3 install -r requirements.txt
```

3. `bsc_cluster.sh reset` builds `create-validator`, then waits for each StakeHub registration transaction to be mined and verifies the validator has positive voting power before finishing reset.

4. Configure the cluster
```
  You can configure the cluster by modifying the following files:
   - `config.toml`
   - `genesis/genesis-template.json`
   - `genesis/scripts/init_holders.template`
   - `.env`
```

5. Setup all nodes.
two different ways, choose as you like.
```bash
bash -x ./bsc_cluster.sh reset # will reset the cluster and start
# The 'vidx' parameter is optional. If provided, its value must be in the range [0, ${BSC_CLUSTER_SIZE}). If omitted, it affects all clusters.
bash -x ./bsc_cluster.sh stop [vidx] # Stops the cluster
bash -x ./bsc_cluster.sh start [vidx] # only start the cluster
bash -x ./bsc_cluster.sh restart [vidx] # start the cluster after stopping it
```

6. Setup a full node.
If you want to run a full node to test snap/full syncing, you can run:

> Attention: it relies on the validator cluster, so you should set up validators by `bsc_cluster.sh` firstly.

```bash
# reset a full sync node0
bash +x ./bsc_fullnode.sh reset 0 full
# reset a snap sync node1
bash +x ./bsc_fullnode.sh reset 1 snap
# restart the snap sync node1
bash +x ./bsc_fullnode.sh restart 1 snap
# stop the snap sync node1
bash +x ./bsc_fullnode.sh stop 1 snap
# clean the snap sync node1
bash +x ./bsc_fullnode.sh clean 1 snap
# reset a full sync node as fast node
bash +x ./bsc_fullnode.sh reset 2 full "--tries-verify-mode none"
# reset a snap sync node with prune ancient
bash +x ./bsc_fullnode.sh reset 3 snap "--pruneancient"
```

You can see the logs in `.local/fullnode`.

Generally, you need to wait for the validator to produce a certain amount of blocks before starting the full/snap syncing test, such as 1000 blocks.

## Downloader Experiment 1

Experiment 1 uses a one-validator chain, one normal-sync control node, one victim, a Bootnode, and a 50-peer topology. The victim's discovery database contains 6 malicious and 10 honest peers (including the validator); 33 malicious and 1 honest peer actively dial the victim. Set `BSC_CLUSTER_SIZE=1` in `.env`, then run:

```bash
./run_experiment_1.sh
./run_experiment_1.sh --duration 20  # short smoke run
```

The victim uses the default `MaxPeers=50` and `DialRatio=3`; connection direction is not constrained, and actual connections are recorded. The runner resets and initializes the one-validator chain at the start of every run. It samples for 300 seconds and writes chart CSVs, the reset log, node output logs, a peer manifest, and run metadata under `../data/experiment_1/`. Logs are grouped by node cohort under `logs/`, with validator and Bootnode logs alongside them; internal database files are not archived. It refuses to overwrite an existing successful run; archive that directory before starting another run. Failed runs are cleaned automatically.

## Downloader Experiment 2

Experiment 2 runs five external malicious-to-honest peer compositions with 10 valid trials per group. Every trial resets the one-validator chain and rebuilds a fresh topology. The active dialers are `12/24`, `18/18`, `30/6`, `40/4`, and `33/1`; the victim's discovery database always has 6 malicious and 10 honest seeds. The default observation window is 300 seconds.

```bash
./run_experiment_2.sh
./run_experiment_2.sh --group group_01 --trials 1 --duration 20  # short smoke run
```

The top-level output contains `success_rate.csv` and `final_peer_composition.csv`; per-trial samples, peer snapshots, manifests, metadata, and node logs are stored under `../data/experiment_2/runs/`. Any victim height increase from genesis makes that trial an attack failure. Invalid environments are deleted and retried; only valid trials count toward the 10-run denominator. A run can resume from already completed valid trials when the stored configuration matches.

## Background transactions
```bash
## normal tx
cd txbot
go build
./air-drops

## blob tx
cd txblob
go build
./txblob
```
