package lxc

import (
	"context"
	"encoding/json"
	"fmt"
	"lxdapi/pkg/logger"
)

type ImageInfo struct {
	Fingerprint  string                 `json:"fingerprint"`
	Aliases      []ImageAlias           `json:"aliases"`
	Architecture string                 `json:"architecture"`
	Properties   map[string]interface{} `json:"properties"`
	Public       bool                   `json:"public"`
	Size         int64                  `json:"size"`
	AutoUpdate   bool                   `json:"auto_update"`
	UploadedAt   string                 `json:"uploaded_at"`
	CreatedAt    string                 `json:"created_at"`
}

type ImageAlias struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

func (c *Client) ListImages(ctx context.Context) ([]ImageInfo, error) {
	logger.Info("获取LXD镜像列表")

	cmd := []string{"image", "list", "--format", "json"}
	output, err := c.exec(ctx, cmd...)
	if err != nil {
		return nil, fmt.Errorf("获取镜像列表失败: %v", err)
	}

	var images []ImageInfo
	if err := json.Unmarshal([]byte(output), &images); err != nil {
		return nil, fmt.Errorf("解析镜像列表失败: %v", err)
	}

	logger.OK("获取到 %d 个镜像", len(images))
	return images, nil
}

func (c *Client) DeleteImage(ctx context.Context, fingerprint string) error {
	logger.Info("删除镜像: %s", fingerprint)

	cmd := []string{"image", "delete", fingerprint}
	if _, err := c.exec(ctx, cmd...); err != nil {
		return fmt.Errorf("删除镜像失败: %v", err)
	}

	logger.OK("镜像删除成功: %s", fingerprint)
	return nil
}

func (c *Client) GetImageInfo(ctx context.Context, fingerprint string) (*ImageInfo, error) {
	logger.Info("获取镜像详情: %s", fingerprint)

	cmd := []string{"image", "show", fingerprint, "--format", "json"}
	output, err := c.exec(ctx, cmd...)
	if err != nil {
		return nil, fmt.Errorf("获取镜像详情失败: %v", err)
	}

	var info ImageInfo
	if err := json.Unmarshal([]byte(output), &info); err != nil {
		return nil, fmt.Errorf("解析镜像详情失败: %v", err)
	}

	return &info, nil
}

func (c *Client) ImportImageFromRemote(ctx context.Context, source, alias string) error {
	if source == "" {
		return fmt.Errorf("缺少远程镜像地址")
	}

	args := []string{"image", "copy", source, "local:"}
	if alias != "" {
		args = append(args, "--alias", alias)
	}

	logger.Info("从远程导入镜像: %s", source)
	if _, err := c.exec(ctx, args...); err != nil {
		return fmt.Errorf("导入镜像失败: %v", err)
	}
	logger.OK("镜像导入成功: %s", source)
	return nil
}

func (c *Client) ImportImageFile(ctx context.Context, filePath, alias string) error {
	if filePath == "" {
		return fmt.Errorf("缺少镜像文件路径")
	}

	args := []string{"image", "import", filePath}
	if alias != "" {
		args = append(args, "--alias", alias)
	}

	logger.Info("从文件导入镜像: %s", filePath)
	if _, err := c.exec(ctx, args...); err != nil {
		return fmt.Errorf("导入镜像文件失败: %v", err)
	}
	logger.OK("镜像文件导入成功: %s", filePath)
	return nil
}

func (c *Client) CreateImageAlias(ctx context.Context, alias, fingerprint string) error {
	if alias == "" || fingerprint == "" {
		return fmt.Errorf("别名和指纹不能为空")
	}

	logger.Info("创建镜像别名: %s -> %s", alias, fingerprint)
	if _, err := c.exec(ctx, "image", "alias", "create", alias, fingerprint); err != nil {
		return fmt.Errorf("创建镜像别名失败: %v", err)
	}
	logger.OK("镜像别名创建成功: %s", alias)
	return nil
}

func (c *Client) DeleteImageAlias(ctx context.Context, alias string) error {
	if alias == "" {
		return fmt.Errorf("缺少镜像别名")
	}

	logger.Info("删除镜像别名: %s", alias)
	if _, err := c.exec(ctx, "image", "alias", "delete", alias); err != nil {
		return fmt.Errorf("删除镜像别名失败: %v", err)
	}
	logger.OK("镜像别名删除成功: %s", alias)
	return nil
}
