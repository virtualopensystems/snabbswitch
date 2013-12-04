/*
 * common.h
 *
 *  Created on: Nov 5, 2013
 *
 */

#ifndef COMMON_H_
#define COMMON_H_

#define INSTANCE_CREATED        1
#define INSTANCE_INITIALIZED    2
#define INSTANCE_END            3

#define VHOST_SOCK_NAME         "vhost.sock"

#define MIN(a,b) (((a)<(b))?(a):(b))
#define MAX(a,b) (((a)>(b))?(a):(b))

#define DUMP_PACKETS

struct ServerMsg;

typedef int (*InMsgHandler)(void* context, struct ServerMsg* msg);
typedef int (*PollHandler)(void* context);

struct AppHandlers {
    void* context;
    InMsgHandler in_handler;
    PollHandler poll_handler;
};
typedef struct AppHandlers AppHandlers;

struct VhostUserMsg;

const char* cmd_from_vhostmsg(const struct VhostUserMsg* msg);
void dump_vhostmsg(const struct VhostUserMsg* msg);

int vhost_user_send_fds(int fd, const struct VhostUserMsg *msg, int *fds, size_t fd_num);
int vhost_user_recv_fds(int fd, const struct VhostUserMsg *msg, int *fds, size_t *fd_num);

#endif /* COMMON_H_ */
