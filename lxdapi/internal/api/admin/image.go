package admin

import (
	"github.com/gin-gonic/gin"
	"lxdapi/internal/lxc"
	"lxdapi/internal/service"
	"lxdapi/pkg/logger"
	"lxdapi/pkg/response"
	"os"
	"path/filepath"
)

// GetImages 获取LXD镜像列表
// @Summary 获取LXD镜像列表
// @Tags Admin API - 镜像管理
// @Success 200 {object} response.Response
// @Router /api/admin/images [get]
func GetImages(c *gin.Context) {
	svc := service.NewImageService()
	images, err := svc.List(c.Request.Context())
	if err != nil {
		logger.Error("获取镜像列表失败: %v", err)
		response.Error(c, 500, "获取镜像列表失败: "+err.Error())
		return
	}

	type imageResponse struct {
		Fingerprint  string           `json:"fingerprint"`
		Aliases      []lxc.ImageAlias `json:"aliases"`
		Architecture string           `json:"architecture"`
		Description  string           `json:"description"`
		OS           string           `json:"os"`
		Release      string           `json:"release"`
		Public       bool             `json:"public"`
		AutoUpdate   bool             `json:"auto_update"`
		Size         int64            `json:"size"`
		SizeHuman    string           `json:"size_human"`
		UploadedAt   string           `json:"uploaded_at"`
		CreatedAt    string           `json:"created_at"`
	}

	result := make([]imageResponse, len(images))
	for i, img := range images {
		result[i] = imageResponse{
			Fingerprint:  img.Fingerprint,
			Aliases:      img.Aliases,
			Architecture: img.Architecture,
			Description:  imageProperty(img.Properties, "description"),
			OS:           imageProperty(img.Properties, "os"),
			Release:      imageProperty(img.Properties, "release"),
			Public:       img.Public,
			AutoUpdate:   img.AutoUpdate,
			Size:         img.Size,
			SizeHuman:    formatBytes(img.Size),
			UploadedAt:   img.UploadedAt,
			CreatedAt:    img.CreatedAt,
		}
	}

	response.Success(c, gin.H{
		"images": result,
		"count":  len(result),
	})
}

// SyncImages 同步镜像到数据库
// @Summary 同步镜像
// @Tags Admin API - 镜像管理
// @Success 200 {object} response.Response
// @Router /api/admin/images/sync [post]
func SyncImages(c *gin.Context) {
	svc := service.NewImageService()
	added, updated, deleted, err := svc.Sync(c.Request.Context())
	if err != nil {
		logger.Error("同步镜像失败: %v", err)
		response.Error(c, 500, "同步镜像失败: "+err.Error())
		return
	}

	response.Success(c, gin.H{
		"added":   added,
		"updated": updated,
		"deleted": deleted,
		"message": "镜像同步完成",
	})
}

// ImportImage 从远程镜像源导入
// @Summary 从远程镜像源导入
// @Tags Admin API - 镜像管理
// @Param request body object{source=string,alias=string} true "镜像源地址和别名"
// @Success 200 {object} response.Response
// @Router /api/admin/images/import [post]
func ImportImage(c *gin.Context) {
	var req struct {
		Source string `json:"source" binding:"required"`
		Alias  string `json:"alias"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Error(c, 400, "参数错误: 缺少镜像源地址")
		return
	}

	svc := service.NewImageService()
	if err := svc.ImportRemote(c.Request.Context(), req.Source, req.Alias); err != nil {
		logger.Error("导入镜像失败: %v", err)
		response.Error(c, 500, "导入失败: "+err.Error())
		return
	}

	logger.OK("远程镜像导入完成: %s", req.Source)
	response.Success(c, "镜像导入成功")
}

// UploadImage 上传镜像文件
// @Summary 上传镜像文件
// @Tags Admin API - 镜像管理
// @Accept multipart/form-data
// @Param file formData file true "镜像压缩包"
// @Param alias formData string false "镜像别名"
// @Success 200 {object} response.Response
// @Router /api/admin/images/upload [post]
func UploadImage(c *gin.Context) {
	fileHeader, err := c.FormFile("file")
	if err != nil {
		response.Error(c, 400, "缺少镜像文件")
		return
	}
	alias := c.PostForm("alias")

	tempDir, err := os.MkdirTemp("", "lxdapi-image-upload-*")
	if err != nil {
		response.Error(c, 500, "创建临时目录失败")
		return
	}
	defer os.RemoveAll(tempDir)

	target := filepath.Join(tempDir, filepath.Base(fileHeader.Filename))
	if err := c.SaveUploadedFile(fileHeader, target); err != nil {
		response.Error(c, 500, "保存上传文件失败")
		return
	}

	svc := service.NewImageService()
	if err := svc.Upload(c.Request.Context(), target, alias); err != nil {
		logger.Error("上传镜像失败: %v", err)
		response.Error(c, 500, "上传失败: "+err.Error())
		return
	}

	logger.OK("镜像文件上传完成: %s", fileHeader.Filename)
	response.Success(c, "镜像文件上传成功")
}

// CreateImageAlias 创建镜像别名
// @Summary 创建镜像别名
// @Tags Admin API - 镜像管理
// @Param request body object{alias=string,fingerprint=string} true "别名和指纹"
// @Success 200 {object} response.Response
// @Router /api/admin/images/aliases [post]
func CreateImageAlias(c *gin.Context) {
	var req struct {
		Alias       string `json:"alias" binding:"required"`
		Fingerprint string `json:"fingerprint" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Error(c, 400, "参数错误: 别名和指纹不能为空")
		return
	}

	svc := service.NewImageService()
	if err := svc.AddAlias(c.Request.Context(), req.Alias, req.Fingerprint); err != nil {
		logger.Error("创建镜像别名失败: %v", err)
		response.Error(c, 500, "创建失败: "+err.Error())
		return
	}

	response.Success(c, "镜像别名创建成功")
}

// DeleteImageAlias 删除镜像别名
// @Summary 删除镜像别名
// @Tags Admin API - 镜像管理
// @Param alias path string true "镜像别名"
// @Success 200 {object} response.Response
// @Router /api/admin/images/aliases/:alias [delete]
func DeleteImageAlias(c *gin.Context) {
	alias := c.Param("alias")
	if alias == "" {
		response.Error(c, 400, "缺少镜像别名")
		return
	}

	svc := service.NewImageService()
	if err := svc.DeleteAlias(c.Request.Context(), alias); err != nil {
		logger.Error("删除镜像别名失败: %v", err)
		response.Error(c, 500, "删除失败: "+err.Error())
		return
	}

	response.Success(c, "镜像别名删除成功")
}

// DeleteImage 删除镜像
// @Summary 删除镜像
// @Tags Admin API - 镜像管理
// @Param fingerprint path string true "镜像指纹"
// @Success 200 {object} response.Response
// @Router /api/admin/images/:fingerprint [delete]
func DeleteImage(c *gin.Context) {
	fingerprint := c.Param("fingerprint")
	if fingerprint == "" {
		response.Error(c, 400, "缺少镜像指纹")
		return
	}

	svc := service.NewImageService()
	if err := svc.Delete(c.Request.Context(), fingerprint); err != nil {
		logger.Error("删除镜像失败: %v", err)
		response.Error(c, 500, "删除失败: "+err.Error())
		return
	}

	response.Success(c, "镜像删除成功")
}

func imageProperty(props map[string]interface{}, key string) string {
	if props == nil {
		return ""
	}
	if value, ok := props[key].(string); ok {
		return value
	}
	return ""
}
