/*
 * Copyright (c) 2022 NVIDIA Corporation
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include "common.cuh"
#include "stdexec/execution.hpp"
#include "exec/on.hpp"


#ifdef _NVHPC_CUDA
#include "nvexec/detail/throw_on_cuda_error.cuh"
#include <nvexec/stream_context.cuh>
#include <nvexec/multi_gpu_context.cuh>
#else
namespace nvexec {
  struct stream_receiver_base{};
  struct stream_sender_base{};

  namespace detail {
    struct stream_op_state_base{};
  }

  inline bool is_on_gpu() {
    return false;
  }
}
#endif 

#include <optional>
#include <exec/inline_scheduler.hpp>
#include <exec/static_thread_pool.hpp>

namespace ex = std::execution;

#ifdef _NVHPC_CUDA
namespace nvexec::STDEXEC_STREAM_DETAIL_NS {
  namespace repeat_n {
    template <class OpT>
      class receiver_2_t : public stream_receiver_base {
        using Sender = typename OpT::PredSender;
        using Receiver = typename OpT::Receiver;

        OpT &op_state_;

      public:
        template <stdexec::__one_of<ex::set_error_t, ex::set_stopped_t> _Tag, class... _Args>
          friend void tag_invoke(_Tag __tag, receiver_2_t&& __self, _Args&&... __args) noexcept {
            __self.op_state_.propagate_completion_signal(_Tag{}, (_Args&&)__args...);
          }

        friend void tag_invoke(ex::set_value_t, receiver_2_t&& __self) noexcept {
          using inner_op_state_t = typename OpT::inner_op_state_t;

          OpT &op_state = __self.op_state_;
          op_state.i_++;

          if (op_state.i_ == op_state.n_) {
            op_state.propagate_completion_signal(std::execution::set_value);
            return;
          }

          auto sch = std::execution::get_scheduler(std::execution::get_env(op_state.receiver_));
          inner_op_state_t& inner_op_state = op_state.inner_op_state_.emplace(
              stdexec::__conv{[&]() noexcept {
                return ex::connect(ex::schedule(sch) | op_state.closure_, receiver_2_t<OpT>{op_state});
              }});

          ex::start(inner_op_state);
        }

        friend auto tag_invoke(ex::get_env_t, const receiver_2_t& self) noexcept
          -> make_stream_env_t<stdexec::env_of_t<Receiver>> {
          return make_stream_env(
              stdexec::get_env(self.op_state_.receiver_), 
              std::optional<cudaStream_t>{self.op_state_.stream_});
        }

        explicit receiver_2_t(OpT& op_state)
          : op_state_(op_state)
        {}
      };

    template <class OpT>
      class receiver_1_t : public stream_receiver_base {
        using Receiver = typename OpT::Receiver;

        OpT &op_state_;

      public:
        template <stdexec::__one_of<ex::set_error_t, ex::set_stopped_t> _Tag, class... _Args>
          friend void tag_invoke(_Tag __tag, receiver_1_t&& __self, _Args&&... __args) noexcept {
            __self.op_state_.propagate_completion_signal(_Tag{}, (_Args&&)__args...);
          }

        friend void tag_invoke(ex::set_value_t, receiver_1_t&& __self) noexcept {
          using inner_op_state_t = typename OpT::inner_op_state_t;

          OpT &op_state = __self.op_state_;

          if (op_state.n_) {
            auto sch = std::execution::get_scheduler(std::execution::get_env(op_state.receiver_));
            inner_op_state_t& inner_op_state = op_state.inner_op_state_.emplace(
                stdexec::__conv{[&]() noexcept {
                  return ex::connect(ex::schedule(sch) | op_state.closure_, receiver_2_t<OpT>{op_state});
                }});

            ex::start(inner_op_state);
          } else {
            op_state.propagate_completion_signal(std::execution::set_value);
          }
        }

        friend auto tag_invoke(ex::get_env_t, const receiver_1_t& self) noexcept
          -> make_stream_env_t<stdexec::env_of_t<Receiver>> {
          return make_stream_env(
              stdexec::get_env(self.op_state_.receiver_), 
              std::optional<cudaStream_t>{self.op_state_.stream_});
        }

        explicit receiver_1_t(OpT& op_state)
          : op_state_(op_state)
        {}
      };

    template <class PredecessorSenderId, class ClosureId, class ReceiverId>
      struct operation_state_t : operation_state_base_t<ReceiverId>  {
        using PredSender = stdexec::__t<PredecessorSenderId>;
        using Closure = stdexec::__t<ClosureId>;
        using Receiver = stdexec::__t<ReceiverId>;
        using Scheduler = std::tag_invoke_result_t<std::execution::get_scheduler_t, std::execution::env_of_t<Receiver>>;
        using InnerSender = std::invoke_result_t<Closure, std::tag_invoke_result_t<std::execution::schedule_t, Scheduler>>;

        using predecessor_op_state_t = ex::connect_result_t<PredSender, receiver_1_t<operation_state_t>>;
        using inner_op_state_t = ex::connect_result_t<InnerSender, receiver_2_t<operation_state_t>>;

        PredSender pred_sender_;
        Closure closure_;
        std::optional<predecessor_op_state_t> pred_op_state_;
        std::optional<inner_op_state_t> inner_op_state_;
        std::size_t n_{};
        std::size_t i_{};

        cudaStream_t get_stream() {
          return this->stream_;
        }

        friend void tag_invoke(std::execution::start_t, operation_state_t& op) noexcept {
          op.stream_ = op.allocate();

          if (op.status_ != cudaSuccess) {
            // Couldn't allocate memory for operation state, complete with error
            op.propagate_completion_signal(std::execution::set_error, std::move(op.status_));
          } else {
            if (op.n_) {
              std::execution::start(*op.pred_op_state_);
            } else {
              op.propagate_completion_signal(std::execution::set_value);
            }
          }
        }

        operation_state_t(PredSender&& pred_sender, Closure closure, Receiver&& receiver, std::size_t n)
          : operation_state_base_t<ReceiverId>((Receiver&&)receiver)
          , pred_sender_{(PredSender&&)pred_sender}
          , closure_(closure)
          , n_(n) {
          pred_op_state_.emplace(
            stdexec::__conv{[&]() noexcept {
              return ex::connect((PredSender&&)pred_sender_, receiver_1_t{*this});
            }});
        }
      };
  }
} 
#endif

namespace repeat_n_detail {
  template <class OpT>
    class receiver_t {
      using Receiver = typename OpT::Receiver;

      OpT &op_state_;

    public:
      template <stdexec::__one_of<ex::set_error_t, ex::set_stopped_t> _Tag, class... _Args>
        friend void tag_invoke(_Tag __tag, receiver_t&& __self, _Args&&... __args) noexcept {
          __tag(std::move(__self.op_state_.receiver_), (_Args&&)__args...);
        }

      friend void tag_invoke(ex::set_value_t, receiver_t&& __self) noexcept {
        using inner_op_state_t = typename OpT::inner_op_state_t;

        OpT &op_state = __self.op_state_;
        auto sch = std::execution::get_scheduler(std::execution::get_env(op_state.receiver_));

        for (std::size_t i = 0; i < op_state.n_; i++) {
          std::this_thread::sync_wait(ex::schedule(exec::inline_scheduler{}) | op_state.closure_);
        }

        std::execution::set_value(std::move(op_state.receiver_));
      }

      friend auto tag_invoke(ex::get_env_t, const receiver_t& self) noexcept
        -> stdexec::env_of_t<Receiver> {
        return stdexec::get_env(self.op_state_.receiver_);
      }

      explicit receiver_t(OpT& op_state)
        : op_state_(op_state)
      {}
    };

  template <class SenderId, class ClosureId, class ReceiverId>
    struct operation_state_t {
      using Sender = stdexec::__t<SenderId>;
      using Closure = stdexec::__t<ClosureId>;
      using Receiver = stdexec::__t<ReceiverId>;

      using inner_op_state_t = 
        std::execution::connect_result_t<Sender, receiver_t<operation_state_t>>;

      inner_op_state_t op_state_;
      Closure closure_;
      Receiver receiver_;
      std::size_t n_{};

      friend void
      tag_invoke(std::execution::start_t, operation_state_t &self) noexcept {
        std::execution::start(self.op_state_);
      }

      operation_state_t(Sender&& sender, Closure closure, Receiver&& receiver, std::size_t n)
        : op_state_{std::execution::connect((Sender&&) sender, receiver_t<operation_state_t>{*this})}
        , closure_{closure}
        , receiver_{(Receiver&&)receiver}
        , n_(n) {
      }
    };
}

struct repeat_n_t {
  template <class SenderId, class ClosureId>
    struct repeat_n_sender_t {
      using Sender = stdexec::__t<SenderId>;
      using Closure = stdexec::__t<ClosureId>;

      using completion_signatures = std::execution::completion_signatures<
        std::execution::set_value_t(),
        std::execution::set_stopped_t(),
        std::execution::set_error_t(std::exception_ptr)>;

      Sender sender_;
      Closure closure_;
      std::size_t n_{};

#ifdef _NVHPC_CUDA
      template <stdexec::__decays_to<repeat_n_sender_t> Self, std::execution::receiver Receiver>
        requires (std::tag_invocable<std::execution::connect_t, Sender, Receiver>) &&
                 (!nvexec::STDEXEC_STREAM_DETAIL_NS::receiver_with_stream_env<Receiver>)
      friend auto
      tag_invoke(std::execution::connect_t, Self &&self, Receiver &&r)
        -> repeat_n_detail::operation_state_t<SenderId, ClosureId, stdexec::__x<Receiver>> {
        return repeat_n_detail::operation_state_t<SenderId, ClosureId, stdexec::__x<Receiver>>(
          (Sender&&)self.sender_,
          self.closure_,
          (Receiver&&)r,
          self.n_);
      }

      template <stdexec::__decays_to<repeat_n_sender_t> Self, std::execution::receiver Receiver>
        requires (std::tag_invocable<std::execution::connect_t, Sender, Receiver>) &&
                 (nvexec::STDEXEC_STREAM_DETAIL_NS::receiver_with_stream_env<Receiver>)
      friend auto
      tag_invoke(std::execution::connect_t, Self &&self, Receiver &&r) 
        -> nvexec::STDEXEC_STREAM_DETAIL_NS::repeat_n::operation_state_t<SenderId, ClosureId, stdexec::__x<Receiver>> {
        return nvexec::STDEXEC_STREAM_DETAIL_NS::repeat_n::operation_state_t<SenderId, ClosureId, stdexec::__x<Receiver>>(
          (Sender&&)self.sender_,
          self.closure_,
          (Receiver&&)r,
          self.n_);
      }
#else
      template <stdexec::__decays_to<repeat_n_sender_t> Self, std::execution::receiver Receiver>
        requires std::tag_invocable<std::execution::connect_t, Sender, Receiver> friend auto
      tag_invoke(std::execution::connect_t, Self &&self, Receiver &&r)
        -> repeat_n_detail::operation_state_t<SenderId, ClosureId, stdexec::__x<Receiver>> {
        return repeat_n_detail::operation_state_t<SenderId, ClosureId, stdexec::__x<Receiver>>(
          (Sender&&)self.sender_,
          self.closure_,
          (Receiver&&)r,
          self.n_);
      }
#endif

      template <stdexec::tag_category<std::execution::forwarding_sender_query> Tag, class... Ts>
        requires std::tag_invocable<Tag, Sender, Ts...> friend decltype(auto)
      tag_invoke(Tag tag, const repeat_n_sender_t &s, Ts &&...ts) noexcept {
        return tag(s.sender_, std::forward<Ts>(ts)...);
      }
    };

  template <std::execution::sender Sender,
            stdexec::__sender_adaptor_closure Closure>
    auto operator()(Sender &&__sndr, std::size_t n, Closure closure) const noexcept
      -> repeat_n_sender_t<stdexec::__x<Sender>, stdexec::__x<Closure>> {
      return repeat_n_sender_t<stdexec::__x<Sender>, stdexec::__x<Closure>>{
        std::forward<Sender>(__sndr), closure, n};
    }

  template <stdexec::__sender_adaptor_closure Closure>
    auto operator()(std::size_t n, Closure closure) const
      -> stdexec::__binder_back<repeat_n_t, std::size_t, Closure> {
      return {{}, {}, {n, (Closure&&) closure}};
    }
};

inline constexpr repeat_n_t repeat_n{};

template <class SchedulerT>
[[nodiscard]] bool is_gpu_scheduler(SchedulerT &&scheduler) {
  auto snd = ex::just() | exec::on(scheduler, ex::then([] { return nvexec::is_on_gpu(); }));
  auto [on_gpu] = std::this_thread::sync_wait(std::move(snd)).value();
  return on_gpu;
}

auto maxwell_eqs_snr(float dt,
                     float *time,
                     bool write_results,
                     std::size_t n_iterations,
                     fields_accessor accessor,
                     std::execution::scheduler auto &&computer) {
  return ex::just()
       | exec::on(computer,
                  repeat_n(n_iterations,
                           ex::bulk(accessor.cells, update_h(accessor))
                         | ex::bulk(accessor.cells, update_e(time, dt, accessor))))
       | ex::then(dump_vtk(write_results, accessor));
}

void run_snr(float dt,
             bool write_vtk,
             std::size_t n_iterations,
             grid_t &grid,
             std::string_view scheduler_name,
             std::execution::scheduler auto &&computer) {
  time_storage_t time{is_gpu_scheduler(computer)};
  fields_accessor accessor = grid.accessor();

  auto init = ex::just() 
            | exec::on(computer, ex::bulk(grid.cells, grid_initializer(dt, accessor)));
  std::this_thread::sync_wait(init);

  auto snd = maxwell_eqs_snr(dt,
                             time.get(),
                             write_vtk,
                             n_iterations,
                             accessor,
                             computer);

  report_performance(grid.cells,
                     n_iterations,
                     scheduler_name,
                     [&snd] { std::this_thread::sync_wait(std::move(snd)); });
}
