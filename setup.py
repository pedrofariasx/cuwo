import os
import platform
import numpy
from setuptools import setup, Extension
from Cython.Build import cythonize
from cuwo.download import download_dependencies

# Detecta arquitetura
arch = platform.machine().lower()
is_x86 = arch in ('amd64', 'x86_64', 'i386', 'i686')
is_arm64 = arch in ('aarch64', 'arm64')

# Diretórios de include
includes = [
    os.path.abspath('./cuwo'),
    os.path.abspath('./terraingen/tgen2/src'),
    os.path.abspath('./terraingen/tgen2/external'),
    numpy.get_include()
]

# Macros e flags
macros = []
undef_macros = []
compile_args = ['-std=c++11']
link_args = []
libraries = []

if is_x86:
    print("Compilando com otimizações SSE2 para x86/x64")
    macros.append(('ENABLE_SSE2', None))

if os.name == 'nt':
    # Windows
    macros += [('_CRT_SECURE_NO_WARNINGS', None), ('WIN32', 1)]
    compile_args += ['/std:c++11', '/Zi']
    libraries += ['advapi32']
else:
    # Linux / Unix / ARM64
    compile_args += ['-fpermissive']

# Extensões principais
names = [
    'cuwo.bytes',
    'cuwo.entity',
    'cuwo.tgen_wrap'
]

tgen_sources = [
    './terraingen/tgen2/src/convert.cpp',
    './terraingen/tgen2/src/rpmalloc.c',
    './terraingen/tgen2/src/mem.cpp',
    './terraingen/tgen2/src/sqlite3.c',
    './terraingen/tgen2/src/tgen.cpp',
    './terraingen/tgen2/external/undname/undname.c',
    './terraingen/tgen2/external/pe-parse/parser-library/buffer.cpp',
    './terraingen/tgen2/external/pe-parse/parser-library/parse.cpp'
]

ext_args = dict(
    language='c++',
    include_dirs=includes,
    extra_compile_args=compile_args,
    extra_link_args=link_args,
    define_macros=macros,
    undef_macros=undef_macros,
    libraries=libraries
)

# Extensão tgen
ext_modules = [
    Extension('cuwo.tgen', ['./cuwo/tgen.pyx'] + tgen_sources, **ext_args)
]

# Outras extensões
for name in names:
    ext_modules.append(
        Extension(name, ['./%s.pyx' % name.replace('.', '/')], **ext_args)
    )

setup(
    name='cuwo_extensions',
    ext_modules=cythonize(
        ext_modules,
        compiler_directives={'language_level': "3"},
        annotate=True  # gera HTML com análise de Cython (opcional)
    ),
)
