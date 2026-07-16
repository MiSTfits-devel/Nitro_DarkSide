// Minimal headless Platform implementation for the melonDS core (0.9.5),
// just enough to link the tracer. No BIOS/firmware files (FreeBIOS), no
// wifi/LAN/camera, real std::thread primitives for the GPU3D worker.
#include <cstdio>
#include <cstring>
#include <string>
#include <functional>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>

#include "Platform.h"

namespace Platform
{

void Init(int, char**) {}
void DeInit() {}
void StopEmu() {}

int InstanceID() { return 0; }
std::string InstanceFileSuffix() { return ""; }

int GetConfigInt(ConfigEntry entry)
{
    switch (entry)
    {
    case AudioBitrate: return 0;
    default: return 0;
    }
}

bool GetConfigBool(ConfigEntry) { return false; }
std::string GetConfigString(ConfigEntry) { return ""; }
bool GetConfigArray(ConfigEntry, void*) { return false; }

FILE* OpenFile(std::string path, std::string mode, bool mustexist)
{
    if (mustexist)
    {
        FILE* f = fopen(path.c_str(), "rb");
        if (!f) return nullptr;
        fclose(f);
    }
    return fopen(path.c_str(), mode.c_str());
}

FILE* OpenLocalFile(std::string path, std::string mode)
{
    return fopen(path.c_str(), mode.c_str());
}

FILE* OpenDataFile(std::string path)
{
    return fopen(path.c_str(), "rb");
}

struct Thread
{
    std::thread t;
};

Thread* Thread_Create(std::function<void()> func)
{
    Thread* t = new Thread();
    t->t = std::thread(func);
    return t;
}

void Thread_Free(Thread* thread)
{
    if (thread->t.joinable()) thread->t.detach();
    delete thread;
}

void Thread_Wait(Thread* thread)
{
    if (thread->t.joinable()) thread->t.join();
}

struct Semaphore
{
    std::mutex m;
    std::condition_variable cv;
    int count = 0;
};

Semaphore* Semaphore_Create() { return new Semaphore(); }
void Semaphore_Free(Semaphore* sema) { delete sema; }

void Semaphore_Reset(Semaphore* sema)
{
    std::lock_guard<std::mutex> lk(sema->m);
    sema->count = 0;
}

void Semaphore_Wait(Semaphore* sema)
{
    std::unique_lock<std::mutex> lk(sema->m);
    sema->cv.wait(lk, [&] { return sema->count > 0; });
    sema->count--;
}

void Semaphore_Post(Semaphore* sema, int count)
{
    std::lock_guard<std::mutex> lk(sema->m);
    sema->count += count;
    sema->cv.notify_all();
}

struct Mutex
{
    std::mutex m;
};

Mutex* Mutex_Create() { return new Mutex(); }
void Mutex_Free(Mutex* mutex) { delete mutex; }
void Mutex_Lock(Mutex* mutex) { mutex->m.lock(); }
void Mutex_Unlock(Mutex* mutex) { mutex->m.unlock(); }
bool Mutex_TryLock(Mutex* mutex) { return mutex->m.try_lock(); }

void Sleep(u64 usecs)
{
    std::this_thread::sleep_for(std::chrono::microseconds(usecs));
}

void WriteNDSSave(const u8*, u32, u32, u32) {}
void WriteGBASave(const u8*, u32, u32, u32) {}

bool MP_Init() { return false; }
void MP_DeInit() {}
void MP_Begin() {}
void MP_End() {}
int MP_SendPacket(u8*, int, u64) { return 0; }
int MP_RecvPacket(u8*, u64*) { return 0; }
int MP_SendCmd(u8*, int, u64) { return 0; }
int MP_SendReply(u8*, int, u64, u16) { return 0; }
int MP_SendAck(u8*, int, u64) { return 0; }
int MP_RecvHostPacket(u8*, u64*) { return -1; }
u16 MP_RecvReplies(u8*, u64, u16) { return 0; }

bool LAN_Init() { return false; }
void LAN_DeInit() {}
int LAN_SendPacket(u8*, int) { return 0; }
int LAN_RecvPacket(u8*) { return 0; }

void Camera_Start(int) {}
void Camera_Stop(int) {}
void Camera_CaptureFrame(int, u32*, int, int, bool) {}

}
