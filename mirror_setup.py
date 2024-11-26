import logging
import os
import sys
import time

rdma_pipe_pipe = bfrt.rdma_test.pipe

# Port defines
RDMA_PORT_1 = 28
RDMA_PORT_2 = 60
RDMA_PORT_3 = 160

#################################
##### MIRROR SESSIONS TABLE #####
#################################
# In this section, we setup the mirror sessions.
# There is only one session, that is used to truncate/send packets.
PKT_MIN_LENGTH = 100
RDMA_MIRROR_SESSION = 100


def setup_my_mirror_session_table():
    global bfrt, RDMA_MIRROR_SESSION, RDMA_PORT_3, PKT_MIN_LENGTH

    mirror_cfg = bfrt.mirror.cfg

    mirror_cfg.entry_with_normal(
        sid=RDMA_MIRROR_SESSION,
        direction="BOTH",
        session_enable=True,
        ucast_egress_port=RDMA_PORT_3,
        ucast_egress_port_valid=1,
        # max_pkt_len=PKT_MIN_LENGTH,
        # packet_color="GREEN"
    ).push()


setup_my_mirror_session_table()

bfrt.complete_operations()
