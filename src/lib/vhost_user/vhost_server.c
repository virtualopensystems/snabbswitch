/*
 * vhost_server.c
 *
 *  Created on: Nov 11, 2013
 *
 */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fd_list.h"
#include "vhost_server.h"

typedef int (*MsgHandler)(VhostServer* vhost_server, ServerMsg* msg);

static AppHandlers vhost_server_handlers;

VhostServer* new_vhost_server(const char* path)
{
    VhostServer* vhost_server = (VhostServer*) calloc(1, sizeof(VhostServer));

    //TODO: handle errors here

    vhost_server->server = new_server(path);
    init_server(vhost_server->server);

    vhost_server->memory.nregions = 0;


    vhost_server_handlers.context = vhost_server;
    set_handler_server(vhost_server->server, &vhost_server_handlers);

    return vhost_server;
}

int end_vhost_server(VhostServer* vhost_server)
{
    int idx;

    // End server
    end_server(vhost_server->server);
    free(vhost_server->server);
    vhost_server->server = 0;

    for (idx = 0; idx < vhost_server->memory.nregions; idx++) {
        // VhostServerMemoryRegion *region = &vhost_server->memory.regions[idx];
        // unmap region
    }

    return 0;
}

static int64_t _map_user_addr(VhostServer* vhost_server, uint64_t addr)
{
    uint64_t result = 0;
    int idx;

    for (idx = 0; idx < vhost_server->memory.nregions; idx++) {
        VhostServerMemoryRegion *region = &vhost_server->memory.regions[idx];

        if (region->userspace_addr <= addr
                && addr < (region->userspace_addr + region->memory_size)) {
            result = region->mmap_addr + addr - region->userspace_addr;
            break;
        }
    }

    return result;
}

static int _get_features(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);

    msg->msg.u64 = 0; // no features

    return 1; // should reply back
}

static int _set_features(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);
    return 0;
}

static int _set_owner(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);
    return 0;
}

static int _reset_owner(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);
    return 0;
}

static int _set_mem_table(VhostServer* vhost_server, ServerMsg* msg)
{
    int idx;
    fprintf(stdout, "%s\n", __FUNCTION__);

    vhost_server->memory.nregions = 0;

    for (idx = 0; idx < msg->msg.memory.nregions; idx++) {
        if (msg->fds[idx] > 0) {
            VhostServerMemoryRegion *region = &vhost_server->memory.regions[idx];

            region->guest_phys_addr = msg->msg.memory.regions[idx].guest_phys_addr;
            region->memory_size = msg->msg.memory.regions[idx].memory_size;
            region->userspace_addr = msg->msg.memory.regions[idx].userspace_addr;

            assert(idx < msg->fd_num);
            assert(msg->fds[idx] > 0);

            region->mmap_addr = 0;

            vhost_server->memory.nregions++;
        }
    }

    fprintf(stdout, "Got memory.nregions %d\n", vhost_server->memory.nregions);

    return 0;
}

static int _set_log_base(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);
    return 0;
}

static int _set_log_fd(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);
    return 0;
}

static int _set_vring_num(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);
    return 0;
}

static int _set_vring_addr(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);

    int idx = msg->msg.addr.index;

    assert(idx<2);

    (void)
            (struct vring_desc*) _map_user_addr(vhost_server,
                    msg->msg.addr.desc_user_addr);
    (void)
            (struct vring_avail*) _map_user_addr(vhost_server,
                    msg->msg.addr.avail_user_addr);
    (void)
            (struct vring_used*) _map_user_addr(vhost_server,
                    msg->msg.addr.used_user_addr);
    return 0;
}

static int _set_vring_base(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);

    int idx = msg->msg.state.index;

    assert(idx<2);

    vhost_server->vring_base[idx] = msg->msg.state.num;

    return 0;
}

static int _get_vring_base(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);

    int idx = msg->msg.state.index;

    assert(idx<2);

    msg->msg.state.num = vhost_server->vring_base[idx];

    return 1; // should reply back
}

static int _set_vring_kick(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);

    int idx = msg->msg.file.index;

    assert(idx<2);
    assert(msg->fd_num == 1);

    int kickfd = msg->fds[0];

    fprintf(stdout, "Got kickfd 0x%x\n", kickfd);

    return 0;
}

static int _set_vring_call(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);

    int idx = msg->msg.file.index;

    assert(idx<2);
    assert(msg->fd_num == 1);

    int callfd = msg->fds[0];

    fprintf(stdout, "Got callfd 0x%x\n", callfd);

    return 0;
}

static int _set_vring_err(VhostServer* vhost_server, ServerMsg* msg)
{
    fprintf(stdout, "%s\n", __FUNCTION__);
    return 0;
}

static MsgHandler msg_handlers[VHOST_USER_MAX] = {
        0,                  // VHOST_USER_NONE
        _get_features,      // VHOST_USER_GET_FEATURES
        _set_features,      // VHOST_USER_SET_FEATURES
        _set_owner,         // VHOST_USER_SET_OWNER
        _reset_owner,       // VHOST_USER_RESET_OWNER
        _set_mem_table,     // VHOST_USER_SET_MEM_TABLE
        _set_log_base,      // VHOST_USER_SET_LOG_BASE
        _set_log_fd,        // VHOST_USER_SET_LOG_FD
        _set_vring_num,     // VHOST_USER_SET_VRING_NUM
        _set_vring_addr,    // VHOST_USER_SET_VRING_ADDR
        _set_vring_base,    // VHOST_USER_SET_VRING_BASE
        _get_vring_base,    // VHOST_USER_GET_VRING_BASE
        _set_vring_kick,    // VHOST_USER_SET_VRING_KICK
        _set_vring_call,    // VHOST_USER_SET_VRING_CALL
        _set_vring_err,     // VHOST_USER_SET_VRING_ERR
        0                   // VHOST_USER_NET_SET_BACKEND
        };

static int in_msg_server(void* context, ServerMsg* msg)
{
    VhostServer* vhost_server = (VhostServer*) context;
    int result = 0;

    fprintf(stdout, "Processing message: %s\n", cmd_from_vhostmsg(&msg->msg));

    assert(msg->msg.request > VHOST_USER_NONE && msg->msg.request < VHOST_USER_MAX);

    if (msg_handlers[msg->msg.request]) {
        result = msg_handlers[msg->msg.request](vhost_server, msg);
    }

    return result;
}

static int poll_server(void* context)
{
//    VhostServer* vhost_server = (VhostServer*) context;

    return 0;
}

static AppHandlers vhost_server_handlers =
{
        .context = 0,
        .in_handler = in_msg_server,
        .poll_handler = poll_server
};

int poll_vhost_server(VhostServer* vhost_server)
{
    return loop_server(vhost_server->server);
}
