#!/bin/bash

N_CORE=48
PD_CORE=(1 2 4 8)
KV_CORE=(1 2 4 8 16)
DB_CORE=(1 2 4 8 16)
ROUND=(1 2 3)

# SYSBENCH_CORE=8
THREADS=900
EVENTS=10000

TABLES=8
TABLE_SIZE=1000

####################################

main()
{
    echo `date` Start oltp_update_index bench
    setup
    for npd in "${PD_CORE[@]}"
    do
        for nkv in "${KV_CORE[@]}"
        do
            for ndb in "${DB_CORE[@]}"
            do
                start_cluster
                wait_tidb_ready
                prepare_bench
                for round in "${ROUND[@]}"
                do
                    sleep 5
                    run_bench $npd $nkv $ndb $round
                done
                stop_cluster
                sleep 5
            done
        done
    done
}

setup()
{
    write_config
    make_log_dir
    install_deps
}

make_log_dir()
{
    mkdir -p log
}

install_sysbench()
{
    if ! command -v sysbench &> /dev/null
    then
        echo "sysbench could not be found"
        curl -s https://packagecloud.io/install/repositories/akopytov/sysbench/script.deb.sh | sudo bash
        sudo apt -y install sysbench
    fi
}

install_tiup()
{
    if ! command -v tiup &> /dev/null
    then
        echo "tiup could not be found"
        curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
        export PATH=$HOME/.tiup/bin:$PATH

        tiup install pd:v4.0.7
        tiup install tikv:v4.0.7
        tiup install tidb:v4.0.7
    fi
}

install_curl_and_mysql()
{
    if ! command -v curl &> /dev/null
    then
        echo "curl could not be found"
        sudo apt update -y
        sudo apt install -y curl
    fi

    if ! command -v mysql &> /dev/null
    then
        echo "mysql could not be found"
        sudo apt update -y
        sudo apt install -y mysql-client-core-8.0
    fi
}

install_deps()
{
    install_curl_and_mysql
    install_sysbench
    install_tiup

    # nvme
    # mkfs -t ext4 /dev/nvme0n1;mkdir /ssd; chmod 777 /ssd; mount /dev/nvme0n1 /ssd;lsblk
    # ln -s /ssd $HOME/.tiup;
}

core_range()
{
    # echo ">> core_range was called as : taskset -c $1-$(($1 + $2 - 1))"
    echo "taskset -c $1-$(($1 + $2 - 1))"
}

start_pd()
{
    PD_START=40
    echo "pd was called as : `core_range $PD_START $npd`"

    `core_range $PD_START $npd` $HOME/.tiup/components/pd/v4.0.7/pd-server \
    --name=pd-0 --data-dir=$HOME/.tiup/data/rr/pd-0/data \
    --peer-urls=http://127.0.0.1:2380 \
    --advertise-peer-urls=http://127.0.0.1:2380 \
    --client-urls=http://127.0.0.1:2379 \
    --advertise-client-urls=http://127.0.0.1:2379 \
    --log-file=$HOME/.tiup/data/rr/pd-0/pd.log \
    --initial-cluster=pd-0=http://127.0.0.1:2380 &

    echo pd pid: $! 

}

start_kv()
{
    KV_START=24
    echo "kv was called as : `core_range $KV_START $nkv`"

    `core_range $KV_START $nkv` $HOME/.tiup/components/tikv/v4.0.7/tikv-server \
    --addr=127.0.0.1:20160 \
    --advertise-addr=127.0.0.1:20160 \
    --status-addr=127.0.0.1:20180 \
    --pd=http://127.0.0.1:2379 \
    --config=tikv.toml  \
    --data-dir=$HOME/.tiup/data/rr/tikv-0 \
    --log-file=$HOME/.tiup/data/rr/tikv-0/tikv.log &

    echo tikv pid: $! 
}

start_db()
{
    DB_START=8
    echo "db was called as : `core_range $DB_START $ndb`"

    `core_range $DB_START $ndb` $HOME/.tiup/components/tidb/v4.0.7/tidb-server -P 4000 \
    --store=tikv \
    --host=127.0.0.1 \
    --status=10080 \
    --path=127.0.0.1:2379 \
    --log-file=$HOME/.tiup/data/rr/tidb-0/tidb.log \
    --config=tidb.toml &

    echo tidb pid: $!
}

start_cluster()
{
    echo `date` "start with PD(${npd} cores) KV(${nkv} cores) DB(${ndb} cores)"
    rm -rf $HOME/.tiup/data/rr
    start_pd
    start_kv
    start_db
}


stop_instance()
{
    inst=$1
    echo "wait $inst exit"
    while pkill $inst; do 
        sleep 1
        pkill $inst
        printf "."
    done
    echo "$inst exit"
}

stop_cluster()
{
    echo `date` "stop with PD(${npd} cores) KV(${nkv} cores) DB(${ndb} cores)"
    stop_instance tidb-server
    stop_instance tikv-server
    stop_instance pd-server
}

wait_tidb_ready()
{
    sleep 5
    while ! mysql -u root -h 127.0.0.1 -P 4000 -e ";" ; do
        sleep 1
        printf "."
    done
    # echo ":4000 ready"
}

prepare_bench()
{
    mysql -h 127.0.0.1 -P 4000 -uroot -e "drop database if exists sbtest;create database sbtest;set global tidb_disable_txn_auto_retry=off;set global tidb_txn_mode='optimistic';"
    sysbench oltp_update_index --config-file=config prepare --tables=$TABLES --table-size=$TABLE_SIZE
    mysql -h 127.0.0.1 -P 4000 -uroot -e "set global tidb_txn_mode='pessimistic';"
}

run_bench()
{
    # echo "run_bench was called as : $@"
    echo `date` "Do round ${round} with PD(${npd} cores) KV(${nkv} cores) DB(${ndb} cores)"
    printf -v ts  '%(%Y%m%d%H%M%S)T' -1
    LOG_FILE_NAME=log/${ts}_PD_${npd}_KV_${nkv}_DB_${ndb}_THREAD_${THREADS}_EVENTS_${EVENTS}_ROUND_${round}.log
    # echo $LOG_FILE_NAME
    taskset -c 0-7 sysbench oltp_update_index --config-file=config  run \
        --tables=$TABLES --table-size=$TABLE_SIZE --threads=$THREADS --events=$EVENTS --histogram > $LOG_FILE_NAME
}

write_config()
{

cat > tidb.toml << "EOF"
[tikv-client]
# Max gRPC connections that will be established with each tikv-server.
grpc-connection-count = 4

[opentracing]
# Enable opentracing.
enable = true

# Whether to enable the rpc metrics.
rpc-metrics = true

[opentracing.sampler]
# Type specifies the type of the sampler: const, probabilistic, rateLimiting, or remote
type = "const"

# Param is a value passed to the sampler.
# Valid values for Param field are:
# - for "const" sampler, 0 or 1 for always false/true respectively
# - for "probabilistic" sampler, a probability between 0 and 1
# - for "rateLimiting" sampler, the number of spans per second
# - for "remote" sampler, param is the same as for "probabilistic"
# and indicates the initial sampling rate before the actual one
# is received from the mothership
param = 1.0

# SamplingServerURL is the address of jaeger-agent's HTTP sampling server
sampling-server-url = ""

# MaxOperations is the maximum number of operations that the sampler
# will keep track of. If an operation is not tracked, a default probabilistic
# sampler will be used rather than the per operation specific sampler.
max-operations = 0

# SamplingRefreshInterval controls how often the remotely controlled sampler will poll
# jaeger-agent for the appropriate sampling strategy.
sampling-refresh-interval = 0

[opentracing.reporter]
# QueueSize controls how many spans the reporter can keep in memory before it starts dropping
# new spans. The queue is continuously drained by a background go-routine, as fast as spans
# can be sent out of process.
queue-size = 500000

# BufferFlushInterval controls how often the buffer is force-flushed, even if it's not full.
# It is generally not useful, as it only matters for very low traffic services.
buffer-flush-interval = 0

# LogSpans, when true, enables LoggingReporter that runs in parallel with the main reporter
# and logs all submitted spans. Main Configuration.Logger must be initialized in the code
# for this option to have any effect.
log-spans = false

#  LocalAgentHostPort instructs reporter to send spans to jaeger-agent at this address
local-agent-host-port = ""
EOF

cat > tikv.toml << "EOF"
log-level="warn"

[server]
grpc-concurrency = 4 

[rocksdb]
max-open-files = 256

[raftdb]
max-open-files = 256

[storage]
reserve-space = 0
EOF

# sysbench prepare
cat > config << "EOF"
mysql-host=127.0.0.1
mysql-port=4000
mysql-user=root
mysql-password=
mysql-db=sbtest
time=150
threads=16
report-interval=10
db-driver=mysql
rand-type=uniform
EOF

}

main $@; exit
