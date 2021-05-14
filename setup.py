from setuptools import setup, Extension, find_packages
from Cython.Build import cythonize
import Cython.Compiler.Options
Cython.Compiler.Options.annotate = True

extensions = [Extension("cycore.*", ["nes/cycore/*.pyx"])]
extensions = cythonize(extensions, compiler_directives={"language_level": 3, "profile": False, "boundscheck": False, "nonecheck": False, "cdivision": True}, annotate=True)

with open("README.md", "r") as fh:
    long_description = fh.read()

setup(
    name="pyntendo",
    version="0.0.8",
    author="James Murphy",
    author_email="jkmurphy314@gmail.com",
    description="A Nintendo Entertainment System (NES) emulator in Python and Cython",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/jameskmurphy/nes",
    packages=find_packages(),
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],
    python_requires='>=3.6',
    #ext_modules = cythonize("nes/cycore/*.pyx")
    ext_modules = extensions
)