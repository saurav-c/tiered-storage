#include "kvs/kvs_handlers.hpp"

void node_depart_handler(
    unsigned thread_id, Address ip,
    std::unordered_map<unsigned, GlobalHashRing>& global_hash_ring_map,
    std::shared_ptr<spdlog::logger> logger, zmq::socket_t* depart_puller,
    SocketCache& pushers) {
  std::string message = zmq_util::recv_string(depart_puller);
  std::vector<std::string> v;
  split(message, ':', v);

  unsigned tier = stoi(v[0]);
  Address departing_server_ip = v[1];
  logger->info("Received departure for node {} on tier {}.",
               departing_server_ip, tier);

  // update hash ring
  remove_from_hash_ring<GlobalHashRing>(global_hash_ring_map[tier],
                                        departing_server_ip, 0);

  if (thread_id == 0) {
    // tell all worker threads about the node departure
    for (unsigned tid = 1; tid < kThreadNum; tid++) {
      zmq_util::send_string(
          message,
          &pushers[ServerThread(ip, tid).get_node_depart_connect_addr()]);
    }

    for (const auto& pair : global_hash_ring_map) {
      logger->info("Hash ring for tier {} size is {}.",
                   std::to_string(pair.first),
                   std::to_string(pair.second.size()));
    }
  }
}