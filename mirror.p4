/*
    RDMA packet capture with TOFINO
    2024 Kai Lv, ICT, CAS
*/

#include <core.p4>
#if __TARGET_TOFINO__ == 2
#include <t2na.p4>
#else
#include <tna.p4>
#endif

#include "common/headers.p4"
#include "common/util.p4"

typedef bit<8>  pkt_type_t;
const pkt_type_t PKT_TYPE_NORMAL = 1;
const pkt_type_t PKT_TYPE_MIRROR = 2;

/* Mirror Configuration */
const MirrorId_t RDMA_MIRROR_SESSION_1 = 100;
const MirrorId_t RDMA_MIRROR_SESSION_2 = 100;       // 当前用同一个

#if __TARGET_TOFINO__ == 1
typedef bit<3> mirror_type_t;
#else
typedef bit<4> mirror_type_t;
#endif
const mirror_type_t MIRROR_TYPE_I2E = 1;
const mirror_type_t MIRROR_TYPE_E2E = 2;

enum bit<8> internal_header_t {
    NONE               = 0x0,
    IG_INTR_MD         = 0x1,
    EXAMPLE_BRIDGE_HDR = 0x2
}

header mirror_h {
    pkt_type_t  pkt_type;
}

header internal_h {
    PortId_t ig_port;
    bit<7> padding;
}

struct ingress_metadata_t {
    mirror_h header_type;
    internal_h internal_hdr;
}

struct egress_metadata_t {
    mirror_h pkt_type;
    internal_h internal_hdr;
    MirrorId_t egr_mir_ses;   // Egress mirror session ID
}

struct headers_t {
    ethernet_h     ethernet;
}

// ---------------------------------------------------------------------------
// Ingress parser
// ---------------------------------------------------------------------------
parser SwitchIngressParser(
        packet_in pkt,
        out headers_t hdr,
        out ingress_metadata_t ig_md,
        out ingress_intrinsic_metadata_t ig_intr_md) {

    TofinoIngressParser() tofino_parser;

    state start {
        ig_md.internal_hdr.setValid();
        tofino_parser.apply(pkt, ig_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition accept;
    }

}


// ---------------------------------------------------------------------------
// Switch Ingress MAU
// ---------------------------------------------------------------------------
control SwitchIngress(
        inout headers_t hdr,
        inout ingress_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    action set_egress_port(PortId_t dest_port) {
        ig_tm_md.ucast_egress_port = dest_port;
    }

    table  port_fwd {
        key = {
            ig_intr_md.ingress_port : exact;
            // hdr.ipv4.dst_addr : exact;
        }
        actions = {
            set_egress_port;
        }
        size = 16;
        const entries = {
            // 注意:修改位置1/2：
            // 当你使用10G的线做测试时，应该使用下面这两行：
            (128) : set_egress_port(129);
            (129) : set_egress_port(128);
            
            // 而当你使用100G的线时，应该使用下面这两行：
            (28) : set_egress_port(60);
            (60) : set_egress_port(28);

            //(128) : set_egress_port(136);
            //(136) : set_egress_port(128);
        }
    }

    // action bridge_add_example_hdr(PortId_t ig_port) {
    //     hdr.bridged_md.setValid();
    //     hdr.bridged_md.ig_port = ig_port;
    // }

    apply {
        ig_md.header_type.setValid();
        ig_md.header_type.pkt_type = PKT_TYPE_NORMAL;
        ig_md.internal_hdr.setValid();
        ig_md.internal_hdr.ig_port = ig_intr_md.ingress_port;
        port_fwd.apply();
        // ig_md.internal_hdr.padding = 0;
        // bridge_add_example_hdr(ig_intr_md.ingress_port);
        // No need for egress processing, skip it and use empty controls for egress.
        // ig_tm_md.bypass_egress = 1w1;
    }
}


// ---------------------------------------------------------------------------
// Ingress Deparser
// ---------------------------------------------------------------------------
control SwitchIngressDeparser(
        packet_out pkt,
        inout headers_t hdr,
        in ingress_metadata_t ig_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {

    // Checksum() ipv4_checksum;

    apply {
        pkt.emit(ig_md.header_type);
        pkt.emit(ig_md.internal_hdr);
        pkt.emit(hdr);
    }
}



// ---------------------------------------------------------------------------
// Egress parser
// ---------------------------------------------------------------------------
parser SwitchEgressParser(
        packet_in pkt,
        out headers_t hdr,
        out egress_metadata_t eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {

    TofinoEgressParser() tofino_parser;

    state start {
        tofino_parser.apply(pkt, eg_intr_md);
        transition parse_metadata;
    }

    state parse_metadata {
        // T lookahead<T>()：读取T类型数据大小的报头，但不前移数据报指针
        // mirror_h mirror_md = pkt.extract<mirror_h>()
        pkt.extract(eg_md.pkt_type);
        eg_md.pkt_type.setValid();
        transition select(eg_md.pkt_type.pkt_type) {
            PKT_TYPE_MIRROR : parse_mirror_md;
            PKT_TYPE_NORMAL : parse_bridge_hdr;
            default : accept;
        }
    }

    state parse_bridge_hdr {
        eg_md.internal_hdr.setValid();
        pkt.extract(eg_md.internal_hdr);
        transition parse_ethernet;
    }

    state parse_mirror_md {
        // mirror_h mirror_md;
        // pkt.extract(mirror_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition accept;
    }
}

// ---------------------------------------------------------------------------
// Switch Egress MAU
// ---------------------------------------------------------------------------
control SwitchEgress(
        inout headers_t hdr,
        inout egress_metadata_t eg_md,
        in    egress_intrinsic_metadata_t                 eg_intr_md,
        in    egress_intrinsic_metadata_from_parser_t     eg_prsr_md,
        inout egress_intrinsic_metadata_for_deparser_t    eg_dprsr_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_oport_md) {
    
    action set_mirror(MirrorId_t egr_ses) {
        eg_md.egr_mir_ses = egr_ses;
        // eg_md.egr_mir_ses.setValid();
        // eg_md.egr_mir_ses.setValid();
        eg_md.pkt_type.pkt_type = PKT_TYPE_MIRROR;
        eg_dprsr_md.mirror_type = MIRROR_TYPE_E2E;
        #if __TARGET_TOFINO__ != 1
            eg_dprsr_md.mirror_io_select = 1; // E2E mirroring for Tofino2 & future ASICs
        #endif
    }

    table set_mirror_session{
        key ={
            eg_md.internal_hdr.ig_port : exact;
        }
        actions = {
            set_mirror();
        }
        // default_action = set_mirror(RDMA_MIRROR_SESSION_1);   // (不要加这句，除非你想制造DoS攻击hhh)
        size = 16;
        const entries = {
            // 注意:修改位置2/2：
            // 当你使用10G的线做测试时，应该使用下面这两行：
            (128) : set_mirror(RDMA_MIRROR_SESSION_1);
            (129) : set_mirror(RDMA_MIRROR_SESSION_2);
            
            // 而当你使用100G的线时，应该使用下面这两行：
            (28) : set_mirror(RDMA_MIRROR_SESSION_1);
            (60) : set_mirror(RDMA_MIRROR_SESSION_2);
        }
    }
    apply {
        PortId_t ig_port = eg_md.internal_hdr.ig_port;
        if (eg_md.pkt_type.pkt_type == PKT_TYPE_NORMAL) {
            set_mirror_session.apply();
        }
        // set_mirror_session.apply();
    }
}

// ---------------------------------------------------------------------------
// Egress Deparser
// ---------------------------------------------------------------------------
control SwitchEgressDeparser(
        packet_out pkt,
        inout headers_t hdr,
        in egress_metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md) {
    
    Mirror() egr_port_mirror;

    apply {

        if (eg_dprsr_md.mirror_type == MIRROR_TYPE_E2E) {
            egr_port_mirror.emit<mirror_h>(eg_md.egr_mir_ses, {eg_md.pkt_type.pkt_type});
        }
        pkt.emit(hdr.ethernet);
    }
}

Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
