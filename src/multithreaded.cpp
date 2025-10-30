#include "multithreaded.h"
#include <thread>
#include <algorithm>
#include <vector>

static void worker_range(const Matrix &A, const Matrix &B, Matrix &C, int n, int r0, int r1) {
    for (int i = r0; i < r1; ++i) {
        for (int k = 0; k < n; ++k) {
            double a = A[i*n + k];
            for (int j = 0; j < n; ++j) {
                C[i*n + j] += a * B[k*n + j];
            }
        }
    }
}

void matmul_mt(const Matrix &A, const Matrix &B, Matrix &C, int n, int num_threads) {
    std::fill(C.begin(), C.end(), 0.0);
    if (num_threads <= 1) {
        worker_range(A,B,C,n,0,n);
        return;
    }
    std::vector<std::thread> threads;
    int rows_per = std::max(1, n / num_threads);
    int start = 0;
    for (int t = 0; t < num_threads && start < n; ++t) {
        int end = (t == num_threads-1) ? n : std::min(n, start + rows_per);
        threads.emplace_back(worker_range, std::cref(A), std::cref(B), std::ref(C), n, start, end);
        start = end;
    }
    for (auto &th : threads) if (th.joinable()) th.join();
}
