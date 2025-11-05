#include "multithreaded.h"
#include <thread>
#include <algorithm>
#include <vector>

#include "io_utils.h"

static void worker_range(const DMatrix &A, const DMatrix &B, DMatrix &C, const int n, const int r0, const int r1) {
    for (int i = r0; i < r1; i++) {
        for (int k = 0; k < n; k++) {
            const long double a = A[i*n + k];
            for (int j = 0; j < n; j++) {
                C[i*n + j] += a * B[k*n + j];
            }
        }
    }
}

void matmul_mt(const DMatrix &A, const DMatrix &B, DMatrix &C, int n, const int num_threads) {
    std::ranges::fill(C, 0.0);

    if (num_threads <= 1) {
        worker_range(A,B,C,n,0,n);
        return;
    }

    std::vector<std::thread> threads;

    const int rows_per = std::max(1, n / num_threads);
    int start = 0;

    for (int t = 0; t < num_threads && start < n; t++) {
        int end = (t == num_threads-1) ? n : std::min(n, start + rows_per);
        threads.emplace_back(worker_range, std::cref(A), std::cref(B), std::ref(C), n, start, end);
        start = end;
    }

    for (auto &th : threads) if (th.joinable()) th.join();
}
