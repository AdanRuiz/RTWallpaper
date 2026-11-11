#pragma once
// Minimal HTTPS GET to a file with WinHTTP, honouring ETags (If-None-Match) so unchanged
// resources are not downloaded again.
#include <windows.h>
#include <winhttp.h>
#include <string>
#include <vector>

namespace http
{
enum class Result { Downloaded, NotModified, Failed };

inline std::wstring ReadSmallFile(const std::wstring& path)
{
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return L"";
    char buf[512] = {};
    DWORD read = 0;
    ReadFile(f, buf, sizeof(buf) - 1, &read, nullptr);
    CloseHandle(f);
    std::string s(buf, read);
    return std::wstring(s.begin(), s.end());
}

inline void WriteSmallFile(const std::wstring& path, const std::wstring& text)
{
    std::string s(text.begin(), text.end());
    HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(f, s.data(), (DWORD)s.size(), &written, nullptr);
    CloseHandle(f);
}

// Downloads url into outPath (via a temp file, replaced atomically on success).
// If etagPath is given, sends If-None-Match with the stored ETag and saves the new one.
inline Result Download(const std::wstring& url, const std::wstring& outPath, const std::wstring& etagPath = L"",
                       DWORD timeoutMs = 120000)
{
    URL_COMPONENTS uc = { sizeof(uc) };
    wchar_t host[256] = {}, path[2048] = {};
    uc.lpszHostName = host;
    uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = _countof(path);
    wchar_t extra[2048] = {};
    uc.lpszExtraInfo = extra;
    uc.dwExtraInfoLength = _countof(extra);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return Result::Failed;
    std::wstring object = std::wstring(path) + extra;

    Result result = Result::Failed;
    HINTERNET session = WinHttpOpen(L"RTWallpaper/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) return result;
    WinHttpSetTimeouts(session, 15000, 15000, timeoutMs, timeoutMs);
    HINTERNET conn = WinHttpConnect(session, host, uc.nPort, 0);
    HINTERNET req = conn ? WinHttpOpenRequest(conn, L"GET", object.c_str(), nullptr, WINHTTP_NO_REFERER,
                                              WINHTTP_DEFAULT_ACCEPT_TYPES,
                                              uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                         : nullptr;
    if (req)
    {
        std::wstring headers;
        std::wstring etag = etagPath.empty() ? L"" : ReadSmallFile(etagPath);
        if (!etag.empty() && GetFileAttributesW(outPath.c_str()) != INVALID_FILE_ATTRIBUTES)
            headers = L"If-None-Match: " + etag + L"\r\n";
        if (WinHttpSendRequest(req, headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
                               headers.empty() ? 0 : (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
            WinHttpReceiveResponse(req, nullptr))
        {
            DWORD status = 0, size = sizeof(status);
            WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                &status, &size, WINHTTP_NO_HEADER_INDEX);
            if (status == 304)
            {
                result = Result::NotModified;
            }
            else if (status == 200)
            {
                std::wstring tmp = outPath + L".part";
                HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
                bool ok = f != INVALID_HANDLE_VALUE;
                std::vector<char> buf(1 << 20);
                DWORD got = 0;
                ULONGLONG total = 0;
                while (ok && WinHttpReadData(req, buf.data(), (DWORD)buf.size(), &got) && got > 0)
                {
                    DWORD written;
                    ok = WriteFile(f, buf.data(), got, &written, nullptr) && written == got;
                    total += got;
                }
                if (f != INVALID_HANDLE_VALUE) CloseHandle(f);
                if (ok && total > 0 && MoveFileExW(tmp.c_str(), outPath.c_str(), MOVEFILE_REPLACE_EXISTING))
                {
                    result = Result::Downloaded;
                    if (!etagPath.empty())
                    {
                        wchar_t newTag[512] = {};
                        DWORD len = sizeof(newTag);
                        if (WinHttpQueryHeaders(req, WINHTTP_QUERY_ETAG, WINHTTP_HEADER_NAME_BY_INDEX, newTag, &len,
                                                WINHTTP_NO_HEADER_INDEX))
                            WriteSmallFile(etagPath, newTag);
                    }
                }
                else
                {
                    DeleteFileW(tmp.c_str());
                }
            }
        }
        WinHttpCloseHandle(req);
    }
    if (conn) WinHttpCloseHandle(conn);
    WinHttpCloseHandle(session);
    return result;
}
} // namespace http
