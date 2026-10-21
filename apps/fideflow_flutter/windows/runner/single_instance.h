#ifndef FF_SINGLE_INSTANCE_H_
#define FF_SINGLE_INSTANCE_H_
#include <windows.h>
#include <string>

// One player per Windows user and data directory. Separate test profiles remain isolated.
class SingleInstance {
 public:
  SingleInstance();
  ~SingleInstance();
  bool primary() const { return primary_; }
  void Attach(HWND window);
  void RestoreExisting() const;
 private:
  HANDLE instance_ = nullptr;
  HANDLE running_ = nullptr;
  HWND window_ = nullptr;
  bool primary_ = false;
  std::wstring name_;
};
#endif
