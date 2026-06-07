#include <iostream>
#include <stdexcept>
#include <thread>

int main() {
    std::thread t([] { std::cout << "thread ok\n"; });
    t.join();

    try {
        throw std::runtime_error("exception ok");
    } catch (const std::exception& e) {
        std::cout << e.what() << "\n";
    }
    return 0;
}
