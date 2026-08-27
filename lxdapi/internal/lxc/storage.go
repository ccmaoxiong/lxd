package lxc

import (
	"context"
	"encoding/json"
	"fmt"
	"lxdapi/pkg/logger"
	"regexp"
	"sort"
)

type StoragePoolInfo struct {
	Name        string                 `json:"name"`
	Driver      string                 `json:"driver"`
	Description string                 `json:"description"`
	Status      string                 `json:"status"`
	Config      map[string]interface{} `json:"config"`
	UsedBy      []string               `json:"used_by"`
}

type StoragePoolResources struct {
	Space struct {
		Total int64 `json:"total"`
		Used  int64 `json:"used"`
	} `json:"space"`
}

func (c *Client) ListStoragePools(ctx context.Context) ([]StoragePoolInfo, error) {
	logger.Info("获取LXD存储池列表")

	output, err := c.exec(ctx, "storage", "list", "--format", "json")
	if err != nil {
		return nil, fmt.Errorf("获取存储池列表失败: %v", err)
	}

	var pools []StoragePoolInfo
	if err := json.Unmarshal([]byte(output), &pools); err != nil {
		return nil, fmt.Errorf("解析存储池列表失败: %v", err)
	}

	logger.OK("获取到 %d 个存储池", len(pools))
	return pools, nil
}

func (c *Client) GetStoragePoolResources(ctx context.Context, name string) (*StoragePoolResources, error) {
	output, err := c.exec(ctx, "query", "/1.0/storage-pools/"+name+"/resources")
	if err != nil {
		return nil, fmt.Errorf("获取存储池资源失败: %v", err)
	}

	var resources StoragePoolResources
	if err := json.Unmarshal([]byte(output), &resources); err != nil {
		return nil, fmt.Errorf("解析存储池资源失败: %v", err)
	}

	return &resources, nil
}

var validStorageName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)

func (c *Client) CreateStoragePool(ctx context.Context, name, driver, source, size string, config map[string]string) error {
	if !validStorageName.MatchString(name) {
		return fmt.Errorf("存储池名称不合法")
	}
	if !validStorageName.MatchString(driver) {
		return fmt.Errorf("存储池驱动不合法")
	}

	args := []string{"storage", "create", name, driver}
	if source != "" {
		args = append(args, "source="+source)
	}
	if size != "" {
		args = append(args, "size="+size)
	}

	keys := make([]string, 0, len(config))
	for key := range config {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if !validStorageName.MatchString(key) {
			return fmt.Errorf("存储池配置项不合法: %s", key)
		}
		args = append(args, key+"="+config[key])
	}

	logger.Info("创建存储池: %s (%s)", name, driver)
	if _, err := c.exec(ctx, args...); err != nil {
		return fmt.Errorf("创建存储池失败: %v", err)
	}
	logger.OK("存储池创建成功: %s", name)
	return nil
}

func (c *Client) DeleteStoragePool(ctx context.Context, name string) error {
	if !validStorageName.MatchString(name) {
		return fmt.Errorf("存储池名称不合法")
	}

	logger.Info("删除存储池: %s", name)
	if _, err := c.exec(ctx, "storage", "delete", name); err != nil {
		return fmt.Errorf("删除存储池失败: %v", err)
	}
	logger.OK("存储池删除成功: %s", name)
	return nil
}
