#include <iostream>
#include <string>
#include <vector>
#include <chrono>
#include <mpi.h>

#include "io_utils.h"
#include "linear.h"
#include "multithreaded.h"

//TODO: MAKE STOPWATCH

// declare MPI wrapper
void matmul_mpi_distributed(const std::string& data_dir);

using Matrix = std::vector<double>;

int main(int argc, char** argv) {
    std::string mode = "linear";
    std::string data_dir = "/data";
    int threads = 4;

    // parse args like: --mode linear --n 200 --threads 4 --data /data
    for (int i = 1; i < argc; ++i) {
        std::string s = argv[i];
        if (s == "--mode" && i+1 < argc) mode = argv[++i];
        else if (s == "--threads" && i+1 < argc) threads = std::stoi(argv[++i]);
        else if (s == "--data" && i+1 < argc) data_dir = argv[++i];
    }

    //TODO: AUTO DETECT THREADS
    if (mode == "mpi") {
        MPI_Init(&argc, &argv);
        matmul_mpi_distributed(data_dir);
        MPI_Finalize();
        return 0;
    }

    if (mode == "linear") {
        int na = 0, nb = 0;
        std::string pathA = data_dir + "/matA.txt";
        std::string pathB = data_dir + "/matB.txt";
        if (Matrix A, B; read_square_matrix(pathA,A,na) && read_square_matrix(pathB,B,nb) && na==nb) {
            Matrix C;
            int nread = na;

            C.assign(nread*nread,0.0);

            auto t0 = std::chrono::high_resolution_clock::now();

            matmul_linear(A,B,C,nread);

            auto t1 = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double> dt = t1 - t0;

            std::cout << "[linear] n="<<nread<<" time="<<dt.count()<<"s\n";

            write_square_matrix(data_dir + "/matC.txt", C, nread);
        } else {
            std::cout << "[linear] No matrix found!";
        }

        return 0;
    }

    //TODO: AUTO DETECT THREADS
    if (mode == "mt") {
        Matrix A,B,C;
        int na=0, nb=0;
        std::string pathA = data_dir + "/matA.txt";
        std::string pathB = data_dir + "/matB.txt";
        bool okA = read_square_matrix(pathA,A,na);
        bool okB = read_square_matrix(pathB,B,nb);
        if (okA && okB && na==nb) {
            int nread = na;
            C.assign(nread*nread,0.0);
            auto t0 = std::chrono::high_resolution_clock::now();
            matmul_mt(A,B,C,nread, threads);
            auto t1 = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double> dt = t1 - t0;
            std::cout << "[mt] n="<<nread<<" threads="<<threads<<" time="<<dt.count()<<"s\n";
            write_square_matrix(data_dir + "/matC.txt", C, nread);
        } else {
            std::cout << "[mt] No matrix found!";
        }
        return 0;
    }

    std::cerr << "Unknown mode: " << mode << " (use linear | mt | mpi)\n";
    return 1;
}
