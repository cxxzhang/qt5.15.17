#include <algorithm>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

int main()
{
    int answer = 0;
    std::mutex mutex;
    std::thread worker([&] {
        std::lock_guard<std::mutex> lock(mutex);
        std::vector<int> values{42, 41};
        std::sort(values.begin(), values.end());
        answer = values.back();
    });
    worker.join();
    try {
        throw std::runtime_error("runtime-exception");
    } catch (const std::exception &error) {
        if (std::string(error.what()) != "runtime-exception") return 2;
    }
    std::ostringstream output;
    output << answer;
    return output.str() != "42";
}
