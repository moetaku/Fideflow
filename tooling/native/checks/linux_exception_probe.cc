// Exercise exception unwinding with the installed runner's ELF dependency order.
#include <cstdio>
#include <stdexcept>

int main() {
  try {
    throw std::runtime_error("synthetic Fideflow exception fixture");
  } catch (const std::exception&) {
    std::puts("Linux C++ exception unwinding verified.");
    return 0;
  }
  return 1;
}
