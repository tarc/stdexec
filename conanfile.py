from conan import ConanFile
from conan.tools.build import check_min_cppstd, can_run
from conan.tools.cmake import CMake, cmake_layout, CMakeDeps, CMakeToolchain
from conan.tools.files import copy
import requests
import re
from os import path


class P2300Recipe(ConanFile):
    name = "p2300"
    description = "std::execution"
    author = "Michał Dominiak, Lewis Baker, Lee Howes, Kirk Shoop, Michael Garland, Eric Niebler, Bryce Adelstein Lelbach"
    topics = ("WG21", "concurrency")
    homepage = "https://github.com/NVIDIA/stdexec"
    url = "https://github.com/NVIDIA/stdexec"
    license = "Apache 2.0"
    settings = "os", "arch", "compiler", "build_type"
    exports_sources = "include/*", "test/*", "src/*", "CMakeLists.txt", "cmake/*", "examples/*"
    no_copy_source = True
    generators = "CMakeToolchain", "CMakeDeps"

    @property
    def _run_tests(self):
        return not self.conf.get("tools.build:skip_test", default=True)

    def requirements(self):
        self.test_requires("catch2/2.13.7")

    def validate(self):
        check_min_cppstd(self, "20")

    def set_version(self):
        # Get the version from the spec file
        response = requests.get("https://raw.githubusercontent.com/brycelelbach/wg21_p2300_execution/main/execution.bs")
        rev = re.search(r"Revision: (\d+)", response.text).group(1).strip()
        self.version = f"0.{rev}.0"

    def layout(self):
        cmake_layout(self)

    def build(self):
        if self._run_tests:
            cmake = CMake(self)
            cmake.configure()
            cmake.build()
            if can_run(self):
                cmake.test()

    def package(self):
        copy(self, "*.hpp", self.source_folder, self.package_folder)

    def package_info(self):
        self.cpp_info.bindirs = []
        self.cpp_info.libdirs = []

        # Make sure to add the correct flags for gcc
        if self.settings.compiler == "gcc":
            self.cpp_info.cxxflags = ["-fcoroutines", "-Wno-non-template-friend"]

    def package_id(self):
        self.info.clear()
