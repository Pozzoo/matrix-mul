#pragma once
#include <vector>
#include <string>

using Matrix = std::vector<double>;

// read a square matrix from a space-separated text file
// returns true on success; n is set to matrix dimension (n x n)
// file format: each line is a row; columns space-separated; no trailing blanks; no trailing empty line.
bool read_square_matrix(const std::string &path, Matrix &M, int &n);

// write a square matrix to a file
bool write_square_matrix(const std::string &path, const Matrix &M, int n);
