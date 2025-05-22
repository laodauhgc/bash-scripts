#!/bin/bash
CGROUP=$(ls /sys/fs/cgroup/cpu | grep limited_)
if [ -z "$CGROUP" ]; then
    echo "Không tìm thấy cgroup. Script chưa chạy hoặc đã thoát."
    exit 1
fi
echo "Cgroup: $CGROUP"
echo "CPU Quota: $(cat /sys/fs/cgroup/cpu/$CGROUP/cpu.cfs_quota_us) us"
echo "CPU Period: $(cat /sys/fs/cgroup/cpu/$CGROUP/cpu.cfs_period_us) us"
echo "Cores: $(cat /sys/fs/cgroup/cpuset/$CGROUP/cpuset.cpus)"
echo "RAM Limit: $(cat /sys/fs/cgroup/memory/$CGROUP/memory.limit_in_bytes) bytes"
echo "Swap Limit: $(cat /sys/fs/cgroup/memory/$CGROUP/memory.memsw.limit_in_bytes 2>/dev/null) bytes"
echo "PIDs trong cgroup:"
cat /sys/fs/cgroup/cpu/$CGROUP/tasks
