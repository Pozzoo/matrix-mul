#include "io_utils.h"

#include <cmath>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <iostream>

bool read_square_matrix(const std::string &path, DMatrix &M, int &n) {
    std::ifstream f(path, std::ios::binary);  // open binary to preserve BOM
    if (!f.is_open()) return false;

    std::string line;
    std::vector<std::vector<double>> rows;
    rows.clear();
    bool first_line = true;

    while (std::getline(f, line)) {
        if (first_line) {
            first_line = false;
            // Remove UTF-8 BOM if present
            if (!line.empty() && static_cast<unsigned char>(line[0]) == 0xEF &&
                line.size() >= 3 &&
                static_cast<unsigned char>(line[1]) == 0xBB &&
                static_cast<unsigned char>(line[2]) == 0xBF) {
                line.erase(0, 3);
                }
        }

        if (!line.empty() && line.back() == '\r') line.pop_back();  // remove CR if present
        if (line.empty()) continue; // skip empty lines

        std::istringstream ss(line);
        std::vector<double> cols;
        double v;
        while (ss >> v) cols.push_back(v);

        if (cols.empty()) continue;
        rows.push_back(std::move(cols));
    }

    if (rows.empty()) return false;

    n = static_cast<int>(rows.size());

    // Ensure square and consistent columns
    for (const auto &r : rows) {
        if (static_cast<int>(r.size()) != n) {
            std::cerr << "[io] non-square or inconsistent row length in " << path << "\n";
            return false;
        }
    }

    M.assign(n * n, 0.0);

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            M[i*n + j] = rows[i][j];
    return true;
}

double truncate8(const double x) {
    return std::trunc(x * 1000000.0) / 1000000.0;
}

bool write_square_matrix(const std::string &path, const DMatrix &M, const int n) {
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f.is_open()) return false;

    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            const double t = truncate8(static_cast<double>(M[i*n + j]));
            f << std::fixed << std::setprecision(4) << t;
            if (j + 1 < n) f << ' ';
        }
        f << "\r\n"; // Windows CRLF
    }

    return true;
}