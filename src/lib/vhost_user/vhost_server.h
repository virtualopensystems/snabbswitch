/*
 * vhost_server.h
 *
 *  Created on: Nov 11, 2013
 *
 */

#ifndef VHOST_SERVER_H_
#define VHOST_SERVER_H_

#include "server.h"

typedef struct VhostServerMemoryRegion {
    uint64_t guest_phys_addr;
    uint64_t memory_size;
    uint64_t userspace_addr;
    uint64_t mmap_addr;
} VhostServerMemoryRegion;

typedef struct VhostServerMemory {
    uint32_t nregions;
    VhostServerMemoryRegion regions[VHOST_MEMORY_MAX_NREGIONS];
} VhostServerMemory;

typedef struct VhostServer {
    Server* server;
    VhostServerMemory memory;

    unsigned int vring_base[2];
} VhostServer;

VhostServer* new_vhost_server(const char* path);
int end_vhost_server(VhostServer* vhost_server);
int poll_vhost_server(VhostServer* vhost_server);

#endif /* VHOST_SERVER_H_ */
