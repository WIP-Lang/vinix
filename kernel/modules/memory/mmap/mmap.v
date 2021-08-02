module mmap

import memory
import resource
import proc
import errno
import x86.cpu
import x86.cpu.local as cpulocal

const pte_present  = u64(1 << 0)
const pte_writable = u64(1 << 1)
const pte_user     = u64(1 << 2)

pub const prot_none  = 0x00
pub const prot_read  = 0x01
pub const prot_write = 0x02
pub const prot_exec  = 0x04

pub const map_private   = 0x01
pub const map_shared    = 0x02
pub const map_fixed     = 0x04
pub const map_anon      = 0x08
pub const map_anonymous = 0x08

pub struct MmapRangeLocal {
pub mut:
	pagemap &memory.Pagemap
	global  &MmapRangeGlobal
	base    u64
	length  u64
	offset  i64
	prot    int
	flags   int
}

pub struct MmapRangeGlobal {
pub mut:
	shadow_pagemap memory.Pagemap
	locals         []&MmapRangeLocal
	resource       &resource.Resource
	base           u64
	length         u64
	offset         i64
}

fn addr2range(pagemap &memory.Pagemap, addr u64) ?(&MmapRangeLocal, u64, u64) {
	for i := u64(0); i < pagemap.mmap_ranges.len; i++ {
		r := &MmapRangeLocal(pagemap.mmap_ranges[i])
		if addr >= r.base && addr < r.base + r.length {
			memory_page := addr / page_size
			file_page := u64(r.offset) / page_size + (memory_page - r.base / page_size)
			return r, memory_page, file_page
		}
	}
	return none
}

pub fn delete_pagemap(_pagemap &memory.Pagemap) ? {
	mut pagemap := unsafe { _pagemap }

	pagemap.l.acquire()

	for ptr in pagemap.mmap_ranges {
		local_range := &MmapRangeLocal(ptr)

		munmap(pagemap, voidptr(local_range.base), local_range.length) or {
			return error('')
		}
	}

	unsafe { free(pagemap) }
}

pub fn fork_pagemap(_old_pagemap &memory.Pagemap) ?&memory.Pagemap {
	mut old_pagemap := unsafe { _old_pagemap }
	mut new_pagemap := memory.new_pagemap()

	old_pagemap.l.acquire()
	defer {
		old_pagemap.l.release()
	}

	for ptr in old_pagemap.mmap_ranges {
		local_range := &MmapRangeLocal(ptr)
		mut global_range := local_range.global

		mut new_local_range := &MmapRangeLocal{pagemap: voidptr(0),
											   global: voidptr(0)}
		unsafe { new_local_range[0] = local_range[0] }

		if voidptr(global_range.resource) != voidptr(0) {
			global_range.resource.refcount++
		}

		if local_range.flags & map_shared != 0 {
			global_range.locals << new_local_range
			for i := local_range.base; i < local_range.base + local_range.length; i += page_size {
				old_pte := old_pagemap.virt2pte(i, false) or {
					continue
				}
				new_pte := new_pagemap.virt2pte(i, true) or {
					return none
				}
				unsafe { new_pte[0] = old_pte[0] }
			}
		} else {
			mut new_global_range := &MmapRangeGlobal{
				resource: voidptr(0)
				shadow_pagemap: memory.Pagemap{top_level: &u64(0)}
			}

			new_global_range.resource = global_range.resource
			new_global_range.base = global_range.base
			new_global_range.length = global_range.length
			new_global_range.offset = global_range.offset

			new_global_range.locals = []&MmapRangeLocal{}
			new_global_range.locals << new_local_range

			new_global_range.shadow_pagemap.top_level = &u64(memory.pmm_alloc(1))

			if local_range.flags & map_anonymous != 0 {
				for i := local_range.base; i < local_range.base + local_range.length; i += page_size {
					old_pte := old_pagemap.virt2pte(i, false) or {
						continue
					}
					if unsafe { old_pte[0] & 1 } == 0 {
						continue
					}
					new_pte := new_pagemap.virt2pte(i, true) or {
						return none
					}
					new_spte := new_global_range.shadow_pagemap.virt2pte(i, true) or {
						return none
					}
					page := memory.pmm_alloc_nozero(1)
					unsafe {
						C.memcpy(
							voidptr(u64(page) + higher_half),
							voidptr((old_pte[0] & ~(u64(0xfff))) + higher_half),
							page_size
						)
						new_pte[0] = (old_pte[0] & u64(0xfff)) | u64(page)
						new_spte[0] = new_pte[0]
					}
				}
			} else {
				panic('non anon fork')
			}
		}

		new_pagemap.mmap_ranges << voidptr(new_local_range)
	}

	return new_pagemap
}

pub fn map_page_in_range(_g &MmapRangeGlobal, virt_addr u64, phys_addr u64, prot int) ? {
	mut g := unsafe { _g }

	pt_flags := pte_present | pte_user
		| if prot & prot_write != 0 { pte_writable } else { 0 }

	g.shadow_pagemap.map_page(virt_addr, phys_addr, pt_flags) or {
		return error('')
	}

	for i := u64(0); i < g.locals.len; i++ {
		mut l := g.locals[i]
		if virt_addr < l.base || virt_addr >= l.base + l.length {
			continue
		}
		l.pagemap.map_page(virt_addr, phys_addr, pt_flags) or {
			return error('')
		}
	}
}

pub fn map_range(_pagemap &memory.Pagemap, virt_addr u64, phys_addr u64,
				  length u64, prot int, _flags int) ? {
	mut pagemap  := unsafe { _pagemap }
	flags := _flags | map_anonymous

	mut range_local := &MmapRangeLocal{
		pagemap: pagemap
		base: virt_addr
		length: length
		prot: prot
		flags: flags
		global: voidptr(0)
	}

	mut range_global := &MmapRangeGlobal{
		locals: []&MmapRangeLocal{}
		base: virt_addr
		length: length
		resource: voidptr(0)
		shadow_pagemap: memory.Pagemap{top_level: &u64(0)}
	}

	range_local.global = range_global

	range_global.locals << range_local
	range_global.shadow_pagemap.top_level = &u64(memory.pmm_alloc(1))

	pagemap.l.acquire()
	pagemap.mmap_ranges << voidptr(range_local)
	pagemap.l.release()

	for i := u64(0); i < length; i += page_size {
		map_page_in_range(range_global, virt_addr + i, phys_addr + i, prot) or {
			return error('')
		}
	}
}

pub fn pf_handler(gpr_state &cpulocal.GPRState) ? {
	asm volatile amd64 { sti }
	defer {
		asm volatile amd64 { cli }
	}

	mut current_thread := proc.current_thread()
	mut process := current_thread.process
	mut pagemap := process.pagemap

	addr := cpu.read_cr2()

	pagemap.l.acquire()

	range_local, memory_page, _ := addr2range(pagemap, addr) or {
		pagemap.l.release()
		return error('')
	}

	pagemap.l.release()

	if range_local.flags & map_anonymous != 0 {
		page := memory.pmm_alloc(1)
		map_page_in_range(range_local.global, memory_page * page_size, u64(page),
						  range_local.prot) or {
			return error('')
		}
	} else {
		panic('Non anon mmap not supported yet')
	}
}

pub fn syscall_mmap(_ voidptr, addr voidptr, length u64,
					prot_and_flags u64, fd int, offset i64) (u64, u64) {
	C.printf(c'\n\e[32mstrace\e[m: mmap(0x%llx, 0x%llx, 0x%llx, %d, %lld)\n',
			 addr, length, prot_and_flags, fd, offset)
	defer {
		C.printf(c'\e[32mstrace\e[m: returning\n')
	}

	mut resource := &resource.Resource(voidptr(0))

	prot  := int((prot_and_flags >> 32) & 0xffffffff)
	flags := int(prot_and_flags & 0xffffffff)

	if flags & map_anonymous == 0 {
		panic('Non anon mmap not supported yet')
	}

	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	ret := mmap(process.pagemap, addr, length, prot, flags, resource, offset) or {
		return -1, errno.get()
	}

	return u64(ret), 0
}

pub fn mmap(_pagemap &memory.Pagemap, addr voidptr, length u64,
			prot int, flags int, _resource &resource.Resource, offset i64) ?voidptr {
	mut pagemap  := unsafe { _pagemap }
	mut resource := unsafe { _resource }

	if length % page_size != 0 || length == 0 {
		C.printf(c'mmap: length is not a multiple of page size or is 0\n')
		errno.set(errno.einval)
		return none
	}

	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	mut base := u64(0)
	if flags & map_fixed != 0 {
		base = u64(addr)
	} else {
		base = process.mmap_anon_non_fixed_base
		process.mmap_anon_non_fixed_base += length + page_size
	}

	mut range_local := &MmapRangeLocal{
		pagemap: pagemap
		base: base
		length: length
		offset: offset
		prot: prot
		flags: flags
		global: voidptr(0)
	}

	mut range_global := &MmapRangeGlobal{
		locals: []&MmapRangeLocal{}
		base: base
		length: length
		resource: resource
		offset: offset
		shadow_pagemap: memory.Pagemap{top_level: &u64(0)}
	}

	range_local.global = range_global

	range_global.locals << range_local
	range_global.shadow_pagemap.top_level = &u64(memory.pmm_alloc(1))

	pagemap.l.acquire()
	pagemap.mmap_ranges << voidptr(range_local)
	pagemap.l.release()

	if voidptr(resource) != voidptr(0) {
		resource.refcount++
	}

	return voidptr(base)
}

pub fn munmap(_pagemap &memory.Pagemap, addr voidptr, length u64) ? {
	mut pagemap := unsafe { _pagemap }

	if length % page_size != 0 || length == 0 {
		print('\nmunmap: length is not a multiple of page size or it is 0\n')
		return error('')
	}

	for i := u64(addr); i < u64(addr) + length; i += page_size {
		mut local_range, _, _ := addr2range(pagemap, i) or {
			continue
		}

		mut global_range := local_range.global

		snip_begin := i
		for {
			i += page_size
			if i >= local_range.base + local_range.length || i >= u64(addr) + length {
				break
			}
		}
		snip_end := i
		snip_size := snip_end - snip_begin

		if snip_begin > local_range.base && snip_end < local_range.base + local_range.length {
			print('\nmunmap: range splits not supported\n')
			return error('')
		}

		for j := snip_begin; j < snip_end; j += page_size {
			pagemap.unmap_page(j) or {}
		}

		if snip_size == local_range.length {
			pagemap.mmap_ranges.delete(pagemap.mmap_ranges.index(local_range))
		}

		if snip_size == local_range.length && global_range.locals.len == 1 {
			if local_range.flags & map_anonymous != 0 {
				for j := global_range.base;
				  j < global_range.base + global_range.length;
				  j += page_size {
					phys := global_range.shadow_pagemap.virt2phys(j) or {
						continue
					}
					global_range.shadow_pagemap.unmap_page(j) or {
						return error('')
					}
					memory.pmm_free(voidptr(phys), 1)
				}
			} else {
				//global_range.resource.munmap(i)
			}
			unsafe { free(local_range) }
		} else {
			if snip_begin == local_range.base {
				local_range.base = snip_end
			} else {
				local_range.length -= snip_size
			}
		}
	}
}
