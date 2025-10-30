#!/bin/bash

# ================================================================
# 多目录部署脚本 - 集成配置版本
# 功能：支持多个目录的自动化部署，包含完整的配置选项
# 作者：自动化部署脚本
# 版本：2.0 (集成配置版本)
# ================================================================

# 错误处理设置
set -e  # 遇到错误立即退出
set -u  # 使用未定义变量时报错
set -o pipefail  # 管道中任何命令失败都会导致整个管道失败

# 信号处理 - 清理临时文件
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "脚本执行失败，退出码: $exit_code"
    fi
    
    # 清理临时文件
    rm -rf temp_deploy_* 2>/dev/null || true
    
    if [ -n "${ARCHIVE_NAME:-}" ] && [ -f "${ARCHIVE_NAME:-}" ] && [ $exit_code -ne 0 ]; then
        print_warning "由于错误，保留压缩包用于调试: $ARCHIVE_NAME"
    fi
}

# 注册退出处理函数
trap cleanup_on_exit EXIT
trap 'print_error "脚本被中断"; exit 130' INT TERM

# ================================================================
# 配置文件路径
# ================================================================

# 配置文件路径（相对于脚本目录）
CONFIG_FILE="deploy.yml"

# ================================================================
# 配置变量声明 - 将从配置文件中读取
# ================================================================

# 服务器连接配置
SERVER_HOST=""
SERVER_USER=""
SERVER_PASS=""
SSH_KEY_PATH=""
AUTH_METHOD=""

# 部署路径配置
REMOTE_PATH=""
PROJECT_NAME=""

# 部署目录和排除模式（将从配置文件读取）
DEPLOY_DIRS=()
EXCLUDE_PATTERNS=()

# 部署行为控制
BACKUP_REMOTE=""
CLEANUP_LOCAL=""
USE_SSHPASS=false

# 操作系统类型（自动检测）
OS=""

# ================================================================
# 脚本功能代码区域
# 注意：配置项已移至 deploy.config 文件中，请在该文件中修改配置
# ================================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_message() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

print_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# 简单的YAML解析函数
parse_yaml() {
    local file="$1"
    local prefix="$2"
    local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    
    sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" "$file" |
    awk -F$fs '{
        indent = length($1)/2;
        vname[indent] = $2;
        for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
        }
    }' | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

# 解析YAML数组
parse_yaml_array() {
    local file="$1"
    local array_name="$2"
    local prefix="$3"
    
    # 提取数组项
    awk "
    /^[[:space:]]*${array_name}:/ { in_array=1; next }
    in_array && /^[[:space:]]*[a-zA-Z_]/ && !/^[[:space:]]*-/ { in_array=0 }
    in_array && /^[[:space:]]*-/ { 
        gsub(/^[[:space:]]*-[[:space:]]*[\"']?/, \"\")
        gsub(/[\"'][[:space:]]*$/, \"\")
        print \$0
    }
    " "$file"
}

# 读取YAML配置文件
load_config() {
    local config_path="$CONFIG_FILE"
    
    # 如果配置文件不存在，尝试在脚本目录中查找
    if [ ! -f "$config_path" ]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        config_path="$script_dir/$CONFIG_FILE"
    fi
    
    if [ ! -f "$config_path" ]; then
        print_error "配置文件不存在: $CONFIG_FILE"
        print_message "请确保配置文件 $CONFIG_FILE 存在于脚本目录中"
        exit 1
    fi
    
    print_message "读取YAML配置文件: $config_path"
    
    # 解析YAML配置
    eval $(parse_yaml "$config_path" "CONFIG_")
    
    # 映射YAML配置到脚本变量
    SERVER_HOST="${CONFIG_server_host:-}"
    SERVER_USER="${CONFIG_server_user:-}"
    SERVER_PASS="${CONFIG_server_password:-}"
    SSH_KEY_PATH="${CONFIG_server_ssh_key_path:-}"
    AUTH_METHOD="${CONFIG_server_auth_method:-password}"
    
    REMOTE_PATH="${CONFIG_deployment_remote_path:-}"
    
    # 自动从项目目录名获取项目名称
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_NAME="$(basename "$script_dir")"
    
    BACKUP_REMOTE="${CONFIG_behavior_backup_remote:-true}"
    CLEANUP_LOCAL="${CONFIG_behavior_cleanup_local:-true}"
    USE_SSHPASS="${CONFIG_behavior_use_sshpass:-false}"
    
    # 解析数组
    print_message "解析部署目录配置..."
    DEPLOY_DIRS=()
    while IFS= read -r dir; do
        if [ -n "$dir" ]; then
            DEPLOY_DIRS+=("$dir")
        fi
    done < <(parse_yaml_array "$config_path" "directories" "CONFIG_")
    
    print_message "解析排除模式配置..."
    EXCLUDE_PATTERNS=()
    while IFS= read -r pattern; do
        if [ -n "$pattern" ]; then
            EXCLUDE_PATTERNS+=("$pattern")
        fi
    done < <(parse_yaml_array "$config_path" "exclude_patterns" "CONFIG_")
    
    # 验证必要的配置项
    if [ -z "$SERVER_HOST" ]; then
        print_error "配置文件中缺少 server.host 配置"
        exit 1
    fi
    
    if [ -z "$SERVER_USER" ]; then
        print_error "配置文件中缺少 server.user 配置"
        exit 1
    fi
    
    if [ -z "$REMOTE_PATH" ]; then
        print_error "配置文件中缺少 deployment.remote_path 配置"
        exit 1
    fi
    
    if [ ${#DEPLOY_DIRS[@]} -eq 0 ]; then
        print_error "配置文件中缺少 deployment.directories 配置"
        exit 1
    fi
    
    print_message "YAML配置文件加载完成"
    print_message "部署目录: ${DEPLOY_DIRS[*]}"
    print_message "排除模式: ${EXCLUDE_PATTERNS[*]}"
}



# 检测操作系统
detect_os() {
    case "$(uname -s)" in
        Linux*)     OS="Linux";;
        Darwin*)    OS="Mac";;
        CYGWIN*)    OS="Windows";;
        MINGW*)     OS="Windows";;
        MSYS*)      OS="Windows";;
        *)          OS="Unknown";;
    esac
    print_message "检测到操作系统: $OS"
}

# 检查必要的工具
check_requirements() {
    # 检测操作系统
    detect_os
    
    # 检查基本工具
    if ! command -v tar &> /dev/null; then
        print_error "tar 命令未找到"
        exit 1
    fi
    
    if ! command -v scp &> /dev/null; then
        print_error "scp 命令未找到"
        exit 1
    fi
    
    if ! command -v ssh &> /dev/null; then
        print_error "ssh 命令未找到"
        exit 1
    fi
    
    # 检查 sshpass（可选）
    if command -v sshpass &> /dev/null; then
        USE_SSHPASS=true
       
    else
        USE_SSHPASS=false
       
    fi
}

# 选择认证方式
choose_auth_method() {
    # 如果已经配置了认证方式，优先使用配置
    if [ "$AUTH_METHOD" = "key" ]; then
        # 密钥认证
        if [ -z "$SSH_KEY_PATH" ]; then
            read -p "请输入SSH私钥路径 (默认: ~/.ssh/id_rsa): " SSH_KEY_PATH
            if [ -z "$SSH_KEY_PATH" ]; then
                SSH_KEY_PATH="$HOME/.ssh/id_rsa"
            fi
        fi
        
        if [ ! -f "$SSH_KEY_PATH" ]; then
            print_error "SSH密钥文件不存在: $SSH_KEY_PATH"
            print_message "请先生成SSH密钥: ssh-keygen -t rsa -b 4096"
            print_message "然后将公钥添加到服务器: ssh-copy-id $SERVER_USER@$SERVER_HOST"
            exit 1
        fi
        print_message "使用SSH密钥认证: $SSH_KEY_PATH"
    elif [ "$AUTH_METHOD" = "password" ]; then
        # 密码认证
        if [ "$USE_SSHPASS" = true ]; then
            print_message "使用sshpass密码认证"
        else
            print_warning "sshpass不可用，将使用交互式密码输入"
            AUTH_METHOD="interactive"
        fi
    elif [ "$AUTH_METHOD" = "interactive" ]; then
        # 交互式认证
        print_message "使用交互式密码认证"
    else
        # 如果没有配置认证方式，则提示用户选择
        echo
        print_message "请选择认证方式:"
        echo "  1. SSH 密钥认证（推荐，无需密码）"
        echo "  2. 交互式密码输入（每次操作都需要输入密码）"
        if [ "$OS" != "Windows" ]; then
            echo "  3. 安装 sshpass 后使用密码认证"
        fi
        echo
        
        while true; do
            read -p "请选择 (1-2): " choice
            case $choice in
                1)
                    AUTH_METHOD="key"
                    read -p "请输入SSH私钥路径 (默认: ~/.ssh/id_rsa): " SSH_KEY_PATH
                    if [ -z "$SSH_KEY_PATH" ]; then
                        SSH_KEY_PATH="$HOME/.ssh/id_rsa"
                    fi
                    
                    if [ ! -f "$SSH_KEY_PATH" ]; then
                        print_error "SSH密钥文件不存在: $SSH_KEY_PATH"
                        print_message "请先生成SSH密钥: ssh-keygen -t rsa -b 4096"
                        print_message "然后将公钥添加到服务器: ssh-copy-id $SERVER_USER@$SERVER_HOST"
                        exit 1
                    fi
                    break
                    ;;
                2)
                    AUTH_METHOD="interactive"
                    print_warning "将使用交互式密码输入，每次SSH连接都需要手动输入密码"
                    break
                    ;;
                *)
                    print_error "无效选择，请输入 1 或 2"
                    ;;
            esac
        done
    fi
}

# 确认和补充服务器配置信息
read_server_config() {
    # 检查必填配置项
    if [ -z "$SERVER_HOST" ]; then
        print_error "服务器地址未配置，请在脚本中设置 SERVER_HOST"
        read -p "请输入远程服务器地址: " SERVER_HOST
    fi
    
    if [ -z "$SERVER_USER" ]; then
        print_error "服务器用户名未配置，请在脚本中设置 SERVER_USER"
        read -p "请输入服务器用户名: " SERVER_USER
    fi
    
    if [ -z "$REMOTE_PATH" ]; then
        print_error "远程部署路径未配置，请在脚本中设置 REMOTE_PATH"
        read -p "请输入远程部署路径: " REMOTE_PATH
    fi
    
    # 检查部署目录配置
    if [ ${#DEPLOY_DIRS[@]} -eq 0 ]; then
        print_error "部署目录未配置，请在脚本中设置 DEPLOY_DIRS 数组"
        read -p "请输入要部署的目录（用空格分隔）: " -a DEPLOY_DIRS
    fi
    
    # 选择认证方式
    choose_auth_method
    
    # 根据认证方式处理密码
    if [ "$AUTH_METHOD" = "password" ] && [ -z "$SERVER_PASS" ]; then
        read -s -p "请输入服务器密码: " SERVER_PASS
        echo
    fi
    
    print_message "服务器配置:"
    echo "  主机: $SERVER_HOST"
    echo "  用户: $SERVER_USER"
    echo "  认证: $AUTH_METHOD"
    if [ "$AUTH_METHOD" = "key" ]; then
        echo "  密钥: $SSH_KEY_PATH"
    fi
    echo "  路径: $REMOTE_PATH"
    echo "  项目: $PROJECT_NAME"
    echo "  部署目录: ${DEPLOY_DIRS[*]}"
    echo
}

# 检查目录是否存在
check_directories() {
    
    local missing_dirs=()
    for dir_config in "${DEPLOY_DIRS[@]}"; do
        # 解析目录配置（格式：源目录:目标目录名）
        local src_dir="${dir_config%%:*}"
        
        if [ ! -d "$src_dir" ]; then
            missing_dirs+=("$src_dir")
        fi
    done
    
    if [ ${#missing_dirs[@]} -gt 0 ]; then
        print_error "以下目录不存在："
        for dir in "${missing_dirs[@]}"; do
            echo "  - $dir"
        done
        exit 1
    fi
    
    
}

# 构建排除参数
build_exclude_args() {
    local exclude_args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args="$exclude_args --exclude=$pattern"
    done
    echo "$exclude_args"
}

# 压缩多个目录
compress_files() {
    print_message "开始压缩文件..."
    
    # 检查部署目录
    check_directories
    
    # 生成时间戳
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    ARCHIVE_NAME="${PROJECT_NAME}_${TIMESTAMP}.tar.gz"
    
    # 构建排除参数
    local exclude_args=$(build_exclude_args)
    
    print_message "部署目录: ${DEPLOY_DIRS[*]}"
    if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
        print_message "排除模式: ${EXCLUDE_PATTERNS[*]}"
    fi
    
    # 创建临时目录用于组织文件结构
    local temp_dir="temp_deploy_$$"
    mkdir -p "$temp_dir"
    print_message "创建压缩包..."
    # 复制各个目录到临时目录
    for dir_config in "${DEPLOY_DIRS[@]}"; do
        # 解析目录配置（格式：源目录:目标目录名）
        local src_dir="${dir_config%%:*}"
        local target_name="${dir_config##*:}"
        
        # 如果没有指定目标名称，使用源目录名
        if [ "$target_name" = "$src_dir" ]; then
            target_name=$(basename "$src_dir")
        fi
        
      
        
        # 使用rsync复制，支持排除模式
        if command -v rsync &> /dev/null; then
            local rsync_excludes=""
            for pattern in "${EXCLUDE_PATTERNS[@]}"; do
                rsync_excludes="$rsync_excludes --exclude=$pattern"
            done
            rsync -av $rsync_excludes "$src_dir/" "$temp_dir/$target_name/"
        else
            # 如果没有rsync，使用cp
            cp -r "$src_dir" "$temp_dir/$target_name"
        fi
        
        if [ $? -ne 0 ]; then
            print_error "复制目录 $src_dir 失败"
            rm -rf "$temp_dir"
            exit 1
        fi
    done
    
    # 压缩临时目录
   
    cd "$temp_dir"
    tar -czf "../$ARCHIVE_NAME" $exclude_args .
    cd ..
    
    # 清理临时目录
    rm -rf "$temp_dir"
    
    if [ $? -eq 0 ]; then
        print_message "文件压缩成功: $ARCHIVE_NAME"
        echo "压缩包大小: $(du -h $ARCHIVE_NAME | cut -f1)"
        echo "压缩内容: ${DEPLOY_DIRS[*]}"
    else
        print_error "文件压缩失败"
        exit 1
    fi
}

# 构建SSH连接参数
build_ssh_args() {
    local ssh_args="-o StrictHostKeyChecking=no"
    
    case $AUTH_METHOD in
        "key")
            ssh_args="$ssh_args -i $SSH_KEY_PATH"
            ;;
        "password")
            # sshpass 方式，参数在调用时添加
            ;;
        "interactive")
            # 交互式，无需额外参数
            ;;
    esac
    
    echo "$ssh_args"
}

# 执行SCP命令
run_scp() {
    local source="$1"
    local target="$2"
    local ssh_args=$(build_ssh_args)
    
    case $AUTH_METHOD in
        "password")
            if [ "$USE_SSHPASS" = true ]; then
                sshpass -p "$SERVER_PASS" scp $ssh_args "$source" "$target"
            else
                print_error "密码认证需要 sshpass，但未安装"
                exit 1
            fi
            ;;
        "key"|"interactive")
            scp $ssh_args "$source" "$target"
            ;;
    esac
}

# 执行SSH命令
run_ssh() {
    local host="$1"
    local command="$2"
    local ssh_args=$(build_ssh_args)
    
    case $AUTH_METHOD in
        "password")
            if [ "$USE_SSHPASS" = true ]; then
                sshpass -p "$SERVER_PASS" ssh $ssh_args "$host" "$command"
            else
                print_error "密码认证需要 sshpass，但未安装"
                exit 1
            fi
            ;;
        "key"|"interactive")
            ssh $ssh_args "$host" "$command"
            ;;
    esac
}

# 上传文件到远程服务器
upload_files() {
    print_message "开始上传文件到服务器..."
    
    # 上传文件
    run_scp "$ARCHIVE_NAME" "$SERVER_USER@$SERVER_HOST:$REMOTE_PATH/"
    
    if [ $? -eq 0 ]; then
      :
    else
        print_error "文件上传失败"
        exit 1
    fi
}

# 在远程服务器解压文件（增量部署）
extract_files() {
    print_message "开始在远程服务器进行增量部署..."
    
    # 构建增量备份逻辑
    local backup_script=""
    if [ "$BACKUP_REMOTE" = true ]; then
        backup_script='
        # 创建临时目录来预览即将被覆盖的文件
        TEMP_EXTRACT_DIR="temp_extract_$$"
        mkdir -p "$TEMP_EXTRACT_DIR" 2>/dev/null
        
        # 静默获取文件列表
        tar -tzf "'"$ARCHIVE_NAME"'" > /tmp/new_files_list.txt 2>/dev/null
        
        # 检查哪些现有文件将被覆盖
        BACKUP_DIR="backup_$(date +%Y%m%d_%H%M%S)"
        BACKUP_NEEDED=false
        
        # 静默检查和备份文件
        while IFS= read -r file; do
            # 跳过目录条目（以/结尾）
            if [[ "$file" == */ ]]; then
                continue
            fi
            
            # 检查文件是否存在
            if [ -f "$file" ]; then
                if [ "$BACKUP_NEEDED" = false ]; then
                    mkdir -p "$BACKUP_DIR" 2>/dev/null
                    BACKUP_NEEDED=true
                fi
                
                # 创建备份文件的目录结构
                backup_file_dir="$BACKUP_DIR/$(dirname "$file")"
                mkdir -p "$backup_file_dir" 2>/dev/null
                
                # 备份即将被覆盖的文件
                cp "$file" "$backup_file_dir/" 2>/dev/null || true
            fi
        done < /tmp/new_files_list.txt
        
        # 静默备份，不输出信息
        
        # 清理临时文件
        rm -f /tmp/new_files_list.txt 2>/dev/null'
    else
        backup_script='echo "跳过备份（配置为不备份）"'
    fi
    
    # 构建远程命令
    local remote_commands="cd $REMOTE_PATH
        
        # 检查压缩包是否存在
        if [ ! -f \"$ARCHIVE_NAME\" ]; then
            echo \"错误: 压缩包 $ARCHIVE_NAME 不存在\"
            exit 1
        fi
        
        $backup_script
        
        # 使用tar的覆盖模式解压，保留现有的其他文件
        tar -xzf $ARCHIVE_NAME 2>/dev/null
        
        if [ \$? -eq 0 ]; then
            # 静默清理压缩包
            rm -f $ARCHIVE_NAME 2>/dev/null
        else
            echo \"增量部署失败\"
            exit 1
        fi"
    
    # 在远程服务器执行解压命令
    run_ssh "$SERVER_USER@$SERVER_HOST" "$remote_commands"
    
    if [ $? -eq 0 ]; then
        print_message "增量部署完成"
    else
        print_error "增量部署失败"
        exit 1
    fi
}

# 清理本地临时文件
cleanup() {
    if [ "$CLEANUP_LOCAL" = true ]; then
        print_message "清理本地临时文件..."
        if [ -f "$ARCHIVE_NAME" ]; then
            rm -f "$ARCHIVE_NAME"
        fi
        
        # 清理可能残留的临时目录
        rm -rf temp_deploy_* 2>/dev/null || true
    else
        print_message "保留本地压缩包: $ARCHIVE_NAME"
    fi
}

# 显示配置信息
show_config() {
    print_message "=== 部署配置信息 ==="
    echo "项目名称: $PROJECT_NAME"
    echo "服务器地址: $SERVER_HOST"
    echo "服务器用户: $SERVER_USER"
    echo "远程路径: $REMOTE_PATH"
    echo "部署目录: ${DEPLOY_DIRS[*]}"
    if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
        echo "排除模式: ${EXCLUDE_PATTERNS[*]}"
    fi
    echo "远程备份: $BACKUP_REMOTE"
    echo "本地清理: $CLEANUP_LOCAL"
    echo
}

# 主函数
main() {
    print_message "=== 多目录部署脚本 ==="
    echo
    
    # 加载配置文件
    load_config
    
    # 检查环境
    check_requirements
    
    # 确认服务器配置
    read_server_config
    
    # 显示最终配置
    show_config
    
    # 检查部署目录是否存在
    if [ ${#DEPLOY_DIRS[@]} -eq 0 ]; then
        print_error "没有配置部署目录"
        exit 1
    fi
    
    # 确认部署
    read -p "确认开始部署? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        print_warning "部署已取消"
        exit 0
    fi
    
    echo
    print_message "开始部署流程..."
    
    # 执行部署步骤
    compress_files
    upload_files
    extract_files
    cleanup
    
    print_message "=== 部署完成 ==="
    
    # 显示部署结果
    print_message "部署结果:"
    echo "  - 服务器: $SERVER_HOST"
    echo "  - 路径: $REMOTE_PATH"
    if [ "$CLEANUP_LOCAL" = false ]; then
        echo "  - 本地压缩包已保留"
    fi
}

# 脚本入口
main "$@"
