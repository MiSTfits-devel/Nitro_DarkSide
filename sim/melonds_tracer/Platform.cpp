// Minimal headless Platform implementation for the melonDS core (1.1),
// just enough to link the tracer. No BIOS/firmware files (FreeBIOS +
// generated firmware), no wifi/LAN/camera/mic, real std::thread
// primitives for the GPU3D worker.
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <string>
#include <functional>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>

#include "Platform.h"

namespace melonDS::Platform
{

void SignalStop(StopReason reason, void* userdata)
{
    fprintf(stderr, "Platform::SignalStop(%d)\n", (int)reason);
}

std::string GetLocalFilePath(const std::string& filename) { return filename; }

constexpr unsigned MODE_READ     = FileMode::Read;
constexpr unsigned MODE_WRITE    = FileMode::Write;
constexpr unsigned MODE_PRESERVE = FileMode::Preserve;
constexpr unsigned MODE_NOCREATE = FileMode::NoCreate;
constexpr unsigned MODE_TEXT     = FileMode::Text;
constexpr unsigned MODE_APPEND   = FileMode::Append;

static const char* GetModeString(unsigned mode)
{
    bool read     = mode & MODE_READ;
    bool write    = mode & MODE_WRITE;
    bool preserve = mode & MODE_PRESERVE;
    bool nocreate = mode & MODE_NOCREATE;
    bool text     = mode & MODE_TEXT;
    bool append   = mode & MODE_APPEND;

    if (append)             return text ? "a+"  : "a+b";
    if (read && write)
    {
        if (preserve || nocreate) return text ? "r+" : "r+b";
        return text ? "w+" : "w+b";
    }
    if (write)              return text ? "w"   : "wb";
    return text ? "r" : "rb";
}

struct FileHandle
{
    FILE* f;
};

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    if ((mode & MODE_NOCREATE) || !(mode & MODE_WRITE))
    {
        FILE* probe = fopen(path.c_str(), "rb");
        if (!probe && !(mode & MODE_WRITE)) return nullptr;
        if (!probe && (mode & MODE_NOCREATE)) return nullptr;
        if (probe) fclose(probe);
    }
    FILE* f = fopen(path.c_str(), GetModeString(mode));
    if (!f) return nullptr;
    return new FileHandle{f};
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
{
    return OpenFile(path, mode);
}

bool FileExists(const std::string& name)
{
    FILE* f = fopen(name.c_str(), "rb");
    if (!f) return false;
    fclose(f);
    return true;
}

bool LocalFileExists(const std::string& name) { return FileExists(name); }
bool CheckFileWritable(const std::string& filepath) { return true; }
bool CheckLocalFileWritable(const std::string& filepath) { return true; }

bool CloseFile(FileHandle* file)
{
    if (!file) return false;
    fclose(file->f);
    delete file;
    return true;
}

bool IsEndOfFile(FileHandle* file) { return feof(file->f) != 0; }

bool FileReadLine(char* str, int count, FileHandle* file)
{
    return fgets(str, count, file->f) != nullptr;
}

u64 FilePosition(FileHandle* file) { return (u64)ftell(file->f); }

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    int o = origin == FileSeekOrigin::Start ? SEEK_SET
          : origin == FileSeekOrigin::Current ? SEEK_CUR : SEEK_END;
    return fseek(file->f, (long)offset, o) == 0;
}

void FileRewind(FileHandle* file) { rewind(file->f); }

u64 FileRead(void* data, u64 size, u64 count, FileHandle* file)
{
    return fread(data, size, count, file->f);
}

bool FileFlush(FileHandle* file) { return fflush(file->f) == 0; }

u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file)
{
    return fwrite(data, size, count, file->f);
}

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    u64 ret = vfprintf(file->f, fmt, args);
    va_end(args);
    return ret;
}

u64 FileLength(FileHandle* file)
{
    long pos = ftell(file->f);
    fseek(file->f, 0, SEEK_END);
    long len = ftell(file->f);
    fseek(file->f, pos, SEEK_SET);
    return (u64)len;
}

void Log(LogLevel level, const char* fmt, ...)
{
    if (level < LogLevel::Info) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
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

bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
{
    std::unique_lock<std::mutex> lk(sema->m);
    if (!sema->cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                           [&] { return sema->count > 0; }))
        return false;
    sema->count--;
    return true;
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

u64 GetMSCount()
{
    return (u64)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

u64 GetUSCount()
{
    return (u64)std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void WriteNDSSave(const u8*, u32, u32, u32, void*) {}
void WriteGBASave(const u8*, u32, u32, u32, void*) {}
void WriteFirmware(const Firmware&, u32, u32, void*) {}
void WriteDateTime(int, int, int, int, int, int, void*) {}

void MP_Begin(void*) {}
void MP_End(void*) {}
int MP_SendPacket(u8*, int, u64, void*) { return 0; }
int MP_RecvPacket(u8*, u64*, void*) { return 0; }
int MP_SendCmd(u8*, int, u64, void*) { return 0; }
int MP_SendReply(u8*, int, u64, u16, void*) { return 0; }
int MP_SendAck(u8*, int, u64, void*) { return 0; }
int MP_RecvHostPacket(u8*, u64*, void*) { return -1; }
u16 MP_RecvReplies(u8*, u64, u16, void*) { return 0; }

int Net_SendPacket(u8*, int, void*) { return 0; }
int Net_RecvPacket(u8*, void*) { return 0; }

void Camera_Start(int, void*) {}
void Camera_Stop(int, void*) {}
void Camera_CaptureFrame(int, u32*, int, int, bool, void*) {}

void Mic_Start(void*) {}
void Mic_Stop(void*) {}
int Mic_ReadInput(s16*, int, void*) { return 0; }

bool Addon_KeyDown(KeyType, void*) { return false; }
void Addon_RumbleStart(u32, void*) {}
void Addon_RumbleStop(void*) {}
float Addon_MotionQuery(MotionQueryType, void*) { return 0.0f; }

AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder*) {}
bool AAC_Configure(AACDecoder*, int, int) { return false; }
bool AAC_DecodeFrame(AACDecoder*, const void*, int, void*, int) { return false; }

DynamicLibrary* DynamicLibrary_Load(const char*) { return nullptr; }
void DynamicLibrary_Unload(DynamicLibrary*) {}
void* DynamicLibrary_LoadFunction(DynamicLibrary*, const char*) { return nullptr; }

}
