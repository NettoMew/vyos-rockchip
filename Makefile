# VyOS for Rockchip（RK3528 / RK3568 / RK3582）— 入口快捷方式。真正的逻辑全在 scripts/build.sh。
BOARDS := e20c m28k r5s e52c

.PHONY: all $(BOARDS) $(addsuffix -dry,$(BOARDS)) builder kernel iso clean distclean help

all: $(BOARDS)

$(BOARDS):
	@scripts/build.sh $@

$(addsuffix -dry,$(BOARDS)):
	@scripts/build.sh $(@:-dry=) --dry-run

# 板无关阶段（RK3528 家族共享产物）
builder:
	@scripts/build.sh --stages deps,sources,overlay,builder

kernel:
	@scripts/build.sh --stages deps,sources,overlay,builder,kernel

iso:
	@scripts/build.sh --stages deps,sources,overlay,builder,kernel,iso

clean:        # 删每板产物与镜像中间件，保内核 deb/ISO/源码树
	rm -rf work/img work/uboot out/*.img

distclean:    # 全清（下次从零构建）
	@echo "work/ 内有容器写入的 root 属主文件，用 sudo 清理"
	sudo rm -rf work out

help:
	@scripts/build.sh --help
