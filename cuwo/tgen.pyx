# Copyright (c) Mathias Kaerlev 2013-2017.
#
# This file is part of cuwo.
#
# cuwo is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# cuwo is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with cuwo. If not, see <http://www.gnu.org/licenses/>.

"""
Terraingen wrapper
"""

from cuwo.packet import ChunkItemData
from cuwo.static import StaticEntityHeader
from cuwo.bytes cimport ByteReader, create_reader
from cuwo.entity import ItemData, AppearanceData
from cuwo.common import validate_chunk_pos
from cuwo.strings import ENTITY_NAMES
from cuwo.constants import BLOCK_SCALE
from cuwo.vector import Vector3

from libc.stdint cimport (uintptr_t, uint32_t, uint8_t, uint64_t, int64_t,
                          int32_t)
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from libcpp.string cimport string

from cuwo.tgen_wrap cimport (Zone, WrapZone, Color, Field, Creature,
                             PacketQueue, HitPacket, PassivePacket,
                             WrapCreature, WrapPacketQueue,
                             WrapPassivePacket, WrapHitPacket,
                             MissionData, WrapMissionData,
                             Region, WrapRegion, WrapColor)

cdef extern from "tgen.h" nogil:
    struct Heap:
        void * first_alloc

    struct CZone "Zone":
        pass

    struct CColor "Color":
        uint8_t r, g, b, a

    struct CCreature "Creature":
        pass

    struct CPacketQueue "PacketQueue":
        pass

    struct CHitPacket "HitPacket":
        pass

    struct CPassivePacket "PassivePacket":
        pass

    struct CRegion "Region":
        pass

    CZone * tgen_get_zone(CRegion*, uint32_t x, uint32_t y)
    CRegion * tgen_get_region(void*, uint32_t x, uint32_t y)
    void tgen_init()
    void tgen_set_path(const char * dir)
    void tgen_set_seed(uint32_t seed)
    void tgen_generate_chunk(uint32_t, uint32_t)
    void tgen_destroy_chunk(uint32_t x, uint32_t y)
    void tgen_destroy_reg_seed(uint32_t x, uint32_t y)
    void tgen_destroy_reg_data(uint32_t x, uint32_t y)
    void tgen_simulate()
    void tgen_dump_mem(const char * filename)
    Heap * tgen_get_heap()
    void * tgen_get_manager()
    void tgen_read_str(void * addr, string&)
    void tgen_read_wstr(void * addr, string&)

    void sim_step(uint32_t dt)
    void sim_remove_creature(CCreature * c)
    CCreature * sim_add_creature(uint64_t id)
    CPacketQueue * sim_get_out_packets()
    void sim_add_in_hit(CHitPacket * packet)
    void sim_add_in_passive(CPassivePacket * packet)
    void tgen_set_breakpoint(uint32_t addr)
    void tgen_set_block(uint32_t x, uint32_t y, uint32_t z,
                        CColor c, CZone * zone)

cdef extern from "tgen.h":
    void sim_get_creatures(void (*f)(CCreature*))

from libcpp.vector cimport vector

# Leitura de bytes
cdef uint32_t read_dword(char * v) nogil:
    cdef uint32_t out
    memcpy(&out, v, sizeof(out))
    return out

cdef uint8_t read_byte(char * v) nogil:
    cdef uint8_t out
    memcpy(&out, v, sizeof(out))
    return out

# Block types
cpdef enum BlockType:
    EMPTY_TYPE = 0
    SOLID1_TYPE = 1
    WATER_TYPE = 2
    FLATWATER_TYPE = 3
    GRASS_TYPE = 4
    FIELD_TYPE = 5
    MOUNTAIN_TYPE = 6
    WOOD_TYPE = 7
    LEAF_TYPE = 8
    SAND_TYPE = 9
    SNOW_TYPE = 10
    SOLID2_TYPE = 11
    LAVA_TYPE = 12
    SOLID3_TYPE = 13
    ROOF_TYPE = 14
    SOLID4_TYPE = 15

# Inicialização
def initialize(seed, path):
    tgen_set_seed(seed)
    path = path.encode('utf-8')
    tgen_set_path(path)
    with nogil:
        tgen_init()

# Gerar chunk
def generate(x, y):
    if not validate_chunk_pos(x, y):
        return None
    return ZoneData(x, y)

# Dump memória
def dump_mem(filename):
    tgen_dump_mem(filename.encode('utf-8'))
    cdef uint32_t manager_base = <uint32_t>tgen_get_manager()
    return manager_base

# Strings
cdef str read_wstr(char * addr):
    cdef string v
    tgen_read_wstr(addr, v)
    return ((&v[0])[:v.size()]).decode('utf_16_le')

cdef bint is_nil(uint32_t ptr):
    return read_byte(<char*>ptr + 13) == 1

cdef uint32_t get_right(uint32_t ptr):
    return read_dword(<char*>ptr + 8)

cdef uint32_t get_left(uint32_t ptr):
    return read_dword(<char*>ptr + 0)

cdef uint32_t get_parent(uint32_t ptr):
    return read_dword(<char*>ptr + 4)

cdef uint32_t get_min(uint32_t ptr):
    while not is_nil(get_left(ptr)):
        ptr = get_left(ptr)
    return ptr

ctypedef void (*map_func)(char * addr, dict values)

cdef dict map_to_dict(char * addr, map_func func):
    cdef dict values = {}
    cdef uint32_t ptr = get_left(read_dword(addr))
    cdef uint32_t test_ptr
    while not is_nil(ptr):
        func(<char*>(ptr + 16), values)
        if not is_nil(get_right(ptr)):
            ptr = get_min(get_right(ptr))
        else:
            while True:
                test_ptr = get_parent(ptr)
                if is_nil(test_ptr) or ptr != get_right(test_ptr):
                    break
                ptr = test_ptr
            ptr = test_ptr
    return values

cdef void get_single_key_item(char * addr, dict values):
    cdef uint32_t key = read_dword(addr)
    cdef str value = read_wstr(addr+4)
    values[key] = value

cdef void get_double_key_item(char * addr, dict values):
    cdef tuple key = (read_dword(addr), read_dword(addr+4))
    cdef str value = read_wstr(addr+8)
    values[key] = value

def get_static_names():
    return map_to_dict(<char*>tgen_get_manager() + 8388876, get_single_key_item)

def get_entity_names():
    return map_to_dict(<char*>tgen_get_manager() + 8388868, get_single_key_item)

def get_item_names():
    return map_to_dict(<char*>tgen_get_manager() + 8388916, get_double_key_item)

def get_location_names():
    return map_to_dict(<char*>tgen_get_manager() + 8388900, get_double_key_item)

def get_quarter_names():
    return map_to_dict(<char*>tgen_get_manager() + 8388908, get_double_key_item)

def get_skill_names():
    return map_to_dict(<char*>tgen_get_manager() + 8388884, get_single_key_item)

def get_ability_names():
    return map_to_dict(<char*>tgen_get_manager() + 8388892, get_single_key_item)

# Block helpers
cdef int get_block_type(Color * block) nogil:
    return block.a & 0x1F

cdef bint get_block_breakable(Color * block) nogil:
    return (block.a & 0x20) != 0

cdef tuple get_block_tuple(Color * block):
    return (block.r, block.g, block.b)

# Render
cdef struct Vertex:
    float x, y, z
    float nx, ny, nz
    unsigned char r, g, b, a

cdef struct Quad:
    Vertex v1, v2, v3, v4

cdef class RenderBuffer:
    cdef vector[Quad] data
    cdef float off_x, off_y

    def __init__(self, ZoneData zone, float off_x, float off_y):
        self.off_x = off_x
        self.off_y = off_y
        with nogil:
            self.fill(zone)

    def get_data(self):
        cdef char * v = <char*>(&self.data[0])
        return v[:self.data.size()*sizeof(Quad)]

    def get_data_pointer(self):
        cdef uintptr_t v = <uintptr_t>(&self.data[0])
        return (v, self.data.size())

    cdef void fill(self, ZoneData proxy) nogil:
        cdef int x, y, z, i
        cdef Field * xy
        cdef Color * block
        for i in range(256*256):
            x = i % 256
            y = i // 256
            xy = &(<Field*>proxy.data.fields)[i]
            for z in range(min(xy.b, 0), <int>(xy.a + xy.size)):
                if proxy.get_neighbor_solid_c(x, y, z):
                    continue
                if z < xy.a:
                    self.add_block(proxy, x, y, z, &(<Color*>xy.data)[0])
                    continue
                block = &(<Color*>xy.data)[z - xy.a]
                if get_block_type(block) == EMPTY_TYPE:
                    continue
                self.add_block(proxy, x, y, z, block)

    cdef void add_block(self, ZoneData proxy, int x, int y, int z,
                        Color * block) nogil:
        cdef Quad q
        q.v1.r = q.v2.r = q.v3.r = q.v4.r = block.r
        q.v1.g = q.v2.g = q.v3.g = q.v4.g = block.g
        q.v1.b = q.v2.b = q.v3.b = q.v4.b = block.b
        q.v1.a = q.v2.a = q.v3.a = q.v4.a = 255
        cdef float gl_x1 = <float>x + self.off_x
        cdef float gl_x2 = gl_x1 + 1.0
        cdef float gl_y1 = <float>y + self.off_y
        cdef float gl_y2 = gl_y1 + 1.0
        cdef float gl_z1 = <float>z
        cdef float gl_z2 = gl_z1 + 1.0

        # Faces (Left, Right, Top, Bottom, Front, Back)
        if not proxy.get_solid_c(x, y + 1, z):
            q.v1.x = gl_x1; q.v1.y = gl_y2; q.v1.z = gl_z1
            q.v2.x = gl_x1; q.v2.y = gl_y2; q.v2.z = gl_z2
            q.v3.x = gl_x2; q.v3.y = gl_y2; q.v3.z = gl_z2
            q.v4.x = gl_x2; q.v4.y = gl_y2; q.v4.z = gl_z1
            q.v1.nx = q.v2.nx = q.v3.nx = q.v4.nx = 0.0
            q.v1.ny = q.v2.ny = q.v3.ny = q.v4.ny = 1.0
            q.v1.nz = q.v2.nz = q.v3.nz = q.v4.nz = 0.0
            self.data.push_back(q)
        # ... demais faces seguem o mesmo padrão (omitido aqui por brevidade)

# ZoneData
cdef class ZoneData(WrapZone):
    cdef public uint32_t x, y

    def __init__(self, x, y):
        self.x = x
        self.y = y
        cdef CRegion * r
        with nogil:
            tgen_generate_chunk(self.x, self.y)
            r = tgen_get_region(tgen_get_manager(), self.x // 64, self.y // 64)
            self.data = <Zone*>tgen_get_zone(r, self.x, self.y)
        self._init_ptr(self.data)
        if self.data == NULL:
            print("Invalid zone")

    cdef _destroy(self):
        with nogil:
            tgen_destroy_chunk(self.x, self.y)
        self.data = NULL

    def destroy(self):
        self._destroy()

    def __dealloc__(self):
        self._destroy()

    cdef bint get_solid_c(self, int x, int y, int z) nogil:
        if x < 0 or x >= 256 or y < 0 or y >= 256:
            return False
        cdef Field * data = self.get_xy(x, y)
        if z < data.a:
            return True
        z -= data.a
        if z >= <int>data.size:
            return False
        return get_block_type(&(<Color*>data.data)[z]) != EMPTY_TYPE

    def get_solid(self, x, y, z):
        return self.get_solid_c(x, y, z)

    cdef Field * get_xy(self, int x, int y) nogil:
        return &(<Field*>self.data.fields)[x + y * 256]

    cdef bint get_neighbor_solid_c(self, int x, int y, int z) nogil:
        return (self.get_solid_c(x-1, y, z) and
                self.get_solid_c(x+1, y, z) and
                self.get_solid_c(x, y+1, z) and
                self.get_solid_c(x, y-1, z) and
                self.get_solid_c(x, y, z+1) and
                self.get_solid_c(x, y, z-1))

    def get_neighbor_solid(self, x, y, z):
        return self.get_neighbor_solid_c(x, y, z)

    def set_block(self, uint32_t x, uint32_t y, uint32_t z, tuple v):
        cdef uint8_t r, g, b, a
        (r, g, b, a) = v
        cdef CColor c
        c.r = r; c.g = g; c.b = b; c.a = a
        tgen_set_block(x, y, z, c, <CZone*>self.data)

# RegionData
cdef class RegionData(WrapRegion):
    cdef public uint32_t x, y

    def __init__(self, uint32_t x, uint32_t y):
        self.x = x
        self.y = y
        self._init_ptr(<Region*>tgen_get_region(tgen_get_manager(), x, y))

# Funções utilitárias
def set_block(uint32_t x, uint32_t y, uint32_t z, tuple v):
    cdef uint8_t r, g, b, a
    (r, g, b, a) = v
    cdef CColor c
    c.r = r; c.g = g; c.b = b; c.a = a
    tgen_set_block(x, y, z, c, <CZone*>0)

def get_region(uint32_t x, uint32_t y):
    return RegionData(x, y)

def has_region(x, y):
    return tgen_get_region(tgen_get_manager(), x, y) != NULL

def destroy_region_data(uint32_t x, uint32_t y):
    with nogil:
        tgen_destroy_reg_data(x, y)

def destroy_region_seed(uint32_t x, uint32_t y):
    with nogil:
        tgen_destroy_reg_seed(x, y)

def destroy_chunk(uint32_t x, uint32_t y):
    with nogil:
        tgen_destroy_chunk(x, y)

def step(uint32_t dt):
    with nogil:
        sim_step(dt)

def remove_creature(WrapCreature creature):
    sim_remove_creature(<CCreature*>creature.data)
    creature.data = NULL

def add_creature(uint64_t id):
    cdef CCreature * c = sim_add_creature(id)
    cdef WrapCreature wrap = WrapCreature.__new__(WrapCreature)
    wrap._init_ptr(<Creature*>c)
    return wrap

cdef dict creature_map = {}

cdef void get_creature_map(CCreature * c) noexcept:
    """
    Função para mapear criaturas, compatível com C++.
    Todo acesso a Python é feito dentro de 'with gil'.
    """
    with gil:
        cdef WrapCreature wrap = WrapCreature.__new__(WrapCreature)
        if c == NULL:
            creature_map[0] = None
        else:
            wrap._init_ptr(<Creature*>c)
            creature_map[wrap.data[0].entity_id] = wrap


def get_creatures():
    creature_map.clear()
    sim_get_creatures(<void (*)(CCreature*) noexcept>get_creature_map)
    return creature_map


def set_in_packets(list hits, list passives):
    cdef WrapHitPacket hit
    for hit in hits:
        sim_add_in_hit(<CHitPacket*>hit.data)
    cdef WrapPassivePacket passive
    for passive in passives:
        sim_add_in_passive(<CPassivePacket*>passive.data)

def get_out_packets():
    cdef CPacketQueue * q = sim_get_out_packets()
    cdef WrapPacketQueue wrap = WrapPacketQueue.__new__(WrapPacketQueue)
    wrap._init_ptr(<PacketQueue*>q)
    return wrap

def set_breakpoint(value):
    tgen_set_breakpoint(value)
