# async 紧循环收不到 SIGTERM —— 用 .mbtx 驱动，几乎不靠 shell

SHELL  := /bin/bash
MOON   ?= $(HOME)/.moon/bin/moon
FIX_CC ?= clang

export MOON FIX_CC

# MOON_CC 是给「编译这个 .mbtx 自己」用的；脚本内部还会把它传给子进程 moon。
RUN = MOON_CC="$(FIX_CC)" "$(MOON)" run --target native cases.mbtx --

.PHONY: help all deps verify bug workaround contrast fixed cases diagnose clean

help:
	@printf '%s\n' \
	  'async 紧循环收不到 SIGTERM（.mbtx 驱动）' \
	  '' \
	  '  make verify      命中问题 lane + 绕过 lane + 对照 lane，本地应全绿' \
	  '  make bug         命中问题 lane：紧循环收到 TERM 仍存活' \
	  '  make workaround  绕过 lane：每轮回到事件循环 → TERM 生效' \
	  '  make contrast    对照 lane：非 async 忙等 → TERM 生效' \
	  '  make fixed       修复验收 lane：紧循环也响应 TERM（上游修好后转 PASS）' \
	  '  make cases       列出用例' \
	  '  make diagnose    打印探针参数与三个程序的循环形态' \
	  '  make deps        同步 registry 索引（首次运行需要）' \
	  '  make clean       清掉 _build' \
	  '' \
	  '直接跑： $(RUN) <子命令>' \
	  "变量： MOON=$(MOON)   FIX_CC=$(FIX_CC)"

all: verify

# .mbtx 的依赖（moonbitlang/async）要靠 registry 索引解析；全新环境里索引是空的，
# 需要先同步一次。同步失败不致命 —— 可能离线，此时改用本地缓存继续。
deps:
	@$(MOON) update --quiet || echo "warn: moon update 失败（可能离线），改用本地缓存"

verify: deps
	@$(RUN) verify

bug: deps
	@$(RUN) bug

workaround: deps
	@$(RUN) workaround

contrast: deps
	@$(RUN) contrast

fixed: deps
	@$(RUN) fixed

cases: deps
	@$(RUN) list

diagnose: deps
	@$(RUN) diagnose

clean:
	@rm -rf _build
	@echo 'cleaned: _build'
