package service

import (
	"context"
	"lxdapi/internal/db"
	"lxdapi/internal/lxc"
	"lxdapi/models"
	"lxdapi/pkg/logger"
)

type ImageService struct {
	lxcClient *lxc.Client
}

func NewImageService() *ImageService {
	return &ImageService{
		lxcClient: lxc.NewClient(),
	}
}

func (s *ImageService) List(ctx context.Context) ([]lxc.ImageInfo, error) {
	return s.lxcClient.ListImages(ctx)
}

func (s *ImageService) Sync(ctx context.Context) (int, int, int, error) {
	return NewTemplateService().SyncFromLXD(ctx)
}

func (s *ImageService) ImportRemote(ctx context.Context, source, alias string) error {
	return s.lxcClient.ImportImageFromRemote(ctx, source, alias)
}

func (s *ImageService) Upload(ctx context.Context, filePath, alias string) error {
	return s.lxcClient.ImportImageFile(ctx, filePath, alias)
}

func (s *ImageService) AddAlias(ctx context.Context, alias, fingerprint string) error {
	return s.lxcClient.CreateImageAlias(ctx, alias, fingerprint)
}

func (s *ImageService) DeleteAlias(ctx context.Context, alias string) error {
	return s.lxcClient.DeleteImageAlias(ctx, alias)
}

func (s *ImageService) Delete(ctx context.Context, fingerprint string) error {
	if err := s.lxcClient.DeleteImage(ctx, fingerprint); err != nil {
		return err
	}

	if err := db.DB.Unscoped().Where("fingerprint = ?", fingerprint).Delete(&models.Template{}).Error; err != nil {
		logger.Warn("从数据库删除镜像记录失败 %s: %v", fingerprint, err)
	}
	logger.OK("镜像删除完成: %s", fingerprint)
	return nil
}
